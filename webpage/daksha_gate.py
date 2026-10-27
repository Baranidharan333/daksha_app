"""Daksha gate for a Python web UI: only the Daksha app can open it.

The same protocol as the standalone gateway (gateway/app.py), but inside the web
UI's own process, so there is no proxy and no second port. It works with any ASGI
app (FastAPI, Starlette, Django's ASGI app, Quart):

    from daksha_gate import DakshaGate, GateSettings
    app.add_middleware(DakshaGate, settings=GateSettings.from_env())

The app trades its launch key for a one-time ticket (POST /_gate/ticket), opens
/_gate/entry with it and gets a session cookie. Every other request needs that
session: without one, pages get an empty 404, other HTTP requests a 401 and
WebSockets are refused.
"""

import hashlib
import hmac
import logging
import os
import re
import secrets
import socket
import time
from dataclasses import dataclass

from starlette.requests import HTTPConnection, Request
from starlette.responses import JSONResponse, RedirectResponse, Response
from starlette.types import ASGIApp, Receive, Scope, Send

log = logging.getLogger("daksha.gate")

GATE = "/_gate"
_MAX_FAILURES = 10  # bad launch keys per client per minute before answering 429


def print_addresses(host: str, port: int) -> None:
    """Prints where the server can be reached and what to type in the app."""
    if host in ("0.0.0.0", "::"):
        name = socket.gethostname().split(".")[0].lower()
        urls = [f"http://{name}.local:{port}/"]
        try:
            # Connecting a UDP socket sends nothing; it only picks the LAN interface.
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
                s.connect(("192.0.2.1", 80))
                urls.append(f"http://{s.getsockname()[0]}:{port}/")
        except OSError:
            pass
        app_address = name if port == 8100 else f"{name}:{port}"
    else:
        urls = [f"http://{host}:{port}/"]
        app_address = host if port == 8100 else f"{host}:{port}"
    print("Daksha web UI reachable at:")
    for url in urls:
        print(f"    {url}")
    print(f"In the Daksha app, connect to: {app_address}", flush=True)


def load_env_file(path: str) -> None:
    """Reads KEY=VALUE lines from [path] into os.environ; real variables win."""
    try:
        with open(path) as f:
            lines = f.read().splitlines()
    except FileNotFoundError:
        return
    for line in lines:
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            key, value = line.split("=", 1)
            os.environ.setdefault(key.strip(), value.strip().strip("'\""))


def _env_secret(name: str) -> str:
    value = os.environ.get(name, "")
    if len(value) < 32:
        raise RuntimeError(
            f"{name} must be a random value of at least 32 characters. "
            "Copy .env.example to .env and fill it in (see the file)."
        )
    return value


def _env_flag(name: str, default: bool) -> bool:
    value = os.environ.get(name, "").strip().lower()
    return default if not value else value not in ("0", "false", "no")


def _env_list(name: str, default: str = "") -> tuple[str, ...]:
    return tuple(v.strip() for v in os.environ.get(name, default).split(",") if v.strip())


@dataclass(frozen=True)
class GateSettings:
    session_secret: bytes
    # One key per device, so a lost device can be revoked alone.
    launch_keys: tuple[bytes, ...]
    cookie_name: str = "daksha_session"
    cookie_secure: bool = True
    ticket_ttl: int = 60
    session_ttl: int = 8 * 3600
    # Path prefixes served without a session, e.g. "/health".
    public_paths: tuple[str, ...] = ()
    # True turns the gate off: any browser can open the web UI (daksha.conf).
    browser_access: bool = False

    @classmethod
    def from_env(cls) -> "GateSettings":
        """Reads the settings described in daksha.conf and .env.example."""
        if _env_flag("BROWSER_ACCESS", False):
            # The gate is off, so its secrets aren't needed.
            return cls(session_secret=b"", launch_keys=(), browser_access=True)
        return cls(
            session_secret=_env_secret("SESSION_SECRET").encode(),
            launch_keys=tuple(k.encode() for k in _env_list("APP_LAUNCH_KEY")),
            cookie_name=os.environ.get("COOKIE_NAME", "daksha_session"),
            cookie_secure=_env_flag("COOKIE_SECURE", True),
            ticket_ttl=int(os.environ.get("TICKET_TTL", "60")),
            session_ttl=int(os.environ.get("SESSION_TTL", str(8 * 3600))),
            public_paths=_env_list("PUBLIC_PATHS"),
        )


class _Tokens:
    """Live tickets or sessions, kept as keyed hashes with their expiry times.

    Process-local: run the web UI with a single worker.
    """

    def __init__(self, secret: bytes) -> None:
        self._secret = secret
        self._expiry: dict[str, float] = {}

    def _digest(self, token: str) -> str:
        return hmac.new(self._secret, token.encode(), hashlib.sha256).hexdigest()

    def add(self, token: str, ttl: int) -> None:
        now = time.monotonic()
        self._expiry = {k: t for k, t in self._expiry.items() if t > now}
        self._expiry[self._digest(token)] = now + ttl

    def valid(self, token: str) -> bool:
        return self._expiry.get(self._digest(token), 0) > time.monotonic()

    def pop(self, token: str) -> bool:
        """Removes [token]; true if it was live, so each ticket works once."""
        return self._expiry.pop(self._digest(token), 0) > time.monotonic()


class _RedactTickets(logging.Filter):
    """Keeps tickets out of the access log (they travel in the /_gate/entry URL)."""

    _pattern = re.compile(r"(ticket=)[^&\s]+")

    def filter(self, record: logging.LogRecord) -> bool:
        if isinstance(record.args, tuple):
            record.args = tuple(
                self._pattern.sub(r"\1[redacted]", a) if isinstance(a, str) else a
                for a in record.args
            )
        return True


def _safe_next(path: str) -> str:
    """Only same-site paths, so /_gate/entry can't redirect elsewhere."""
    if not path.startswith("/") or path.startswith("//") or "\\" in path:
        return "/"
    return path


class DakshaGate:
    """ASGI middleware that serves /_gate/* and lets only sessions through."""

    def __init__(self, app: ASGIApp, settings: GateSettings) -> None:
        if settings.browser_access:
            log.warning("BROWSER_ACCESS is on: any browser can open this web UI")
        elif not settings.launch_keys:
            raise RuntimeError("APP_LAUNCH_KEY must hold at least one key")
        self.app = app
        self.settings = settings
        self._tickets = _Tokens(settings.session_secret)
        self._sessions = _Tokens(settings.session_secret)
        self._failures: dict[str, list[float]] = {}
        logging.getLogger("uvicorn.access").addFilter(_RedactTickets())

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        # With the gate off, /_gate/* is a plain 404 too, so the app sees a
        # server without a gate and opens pages directly.
        if self.settings.browser_access or scope["type"] not in ("http", "websocket"):
            await self.app(scope, receive, send)
            return
        path = scope["path"]
        if scope["type"] == "http" and path.startswith(GATE + "/"):
            response = await self._gate(Request(scope, receive))
            await response(scope, receive, send)
        elif self._is_public(path) or self._has_session(HTTPConnection(scope)):
            await self.app(scope, receive, send)
        elif scope["type"] == "websocket":
            await receive()  # websocket.connect
            await send({"type": "websocket.close", "code": 1008})  # handshake gets a 403
        else:
            wants_page = scope["method"] in ("GET", "HEAD") and "text/html" in HTTPConnection(
                scope
            ).headers.get("accept", "")
            await Response(status_code=404 if wants_page else 401)(scope, receive, send)

    def _is_public(self, path: str) -> bool:
        return any(path.startswith(p) for p in self.settings.public_paths)

    def _has_session(self, conn: HTTPConnection) -> bool:
        session = conn.cookies.get(self.settings.cookie_name)
        return bool(session) and self._sessions.valid(session)

    async def _gate(self, request: Request) -> Response:
        route = (request.method, request.url.path[len(GATE):])
        if route == ("POST", "/ticket"):
            return self._create_ticket(request)
        if route == ("GET", "/entry"):
            return self._entry(request)
        if route == ("GET", "/session"):
            # 204 while the session is valid, else 401; lets a page notice expiry.
            return Response(status_code=204 if self._has_session(request) else 401)
        if route == ("POST", "/logout"):
            return self._logout(request)
        return Response(status_code=404)

    def _rate_limited(self, ip: str) -> bool:
        now = time.monotonic()
        recent = [t for t in self._failures.get(ip, []) if now - t < 60]
        if recent:
            self._failures[ip] = recent
        else:
            self._failures.pop(ip, None)
        return len(recent) >= _MAX_FAILURES

    def _create_ticket(self, request: Request) -> Response:
        ip = request.client.host if request.client else "unknown"
        if self._rate_limited(ip):
            return Response(status_code=429)
        key = request.headers.get("x-app-key", "").encode()
        # Check every key so the timing doesn't reveal which one nearly matched.
        if not sum(hmac.compare_digest(key, k) for k in self.settings.launch_keys):
            self._failures.setdefault(ip, []).append(time.monotonic())
            log.warning("rejected ticket request from %s", ip)
            return Response(status_code=401)
        ticket = secrets.token_urlsafe(32)
        self._tickets.add(ticket, self.settings.ticket_ttl)
        return JSONResponse(
            {"ticket": ticket, "expires_in": self.settings.ticket_ttl},
            headers={"Cache-Control": "no-store"},
        )

    def _entry(self, request: Request) -> Response:
        ticket = request.query_params.get("ticket", "")
        if not ticket or not self._tickets.pop(ticket):
            log.info("rejected ticket exchange from %s", request.client and request.client.host)
            return Response(status_code=403)
        s = self.settings
        # Replace any older session this browser had.
        if old := request.cookies.get(s.cookie_name):
            self._sessions.pop(old)
        session = secrets.token_urlsafe(32)
        self._sessions.add(session, s.session_ttl)
        response = RedirectResponse(
            _safe_next(request.query_params.get("next", "/")), status_code=303
        )
        response.set_cookie(
            s.cookie_name,
            session,
            max_age=s.session_ttl,
            httponly=True,
            secure=s.cookie_secure,
            samesite="lax",
            path="/",
        )
        response.headers["Cache-Control"] = "no-store"
        response.headers["Referrer-Policy"] = "no-referrer"
        return response

    def _logout(self, request: Request) -> Response:
        s = self.settings
        if session := request.cookies.get(s.cookie_name):
            self._sessions.pop(session)
        response = Response(status_code=204)
        response.delete_cookie(
            s.cookie_name, path="/", secure=s.cookie_secure, httponly=True, samesite="lax"
        )
        return response
