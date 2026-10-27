"""Daksha gateway: only the Daksha app can open a robot's web UI.

Runs on the port the app connects to, in front of the real web UI (UPSTREAM_URL),
which must listen on localhost only. The app trades its launch key for a one-time
ticket, opens /_gate/entry with it and gets a session cookie. Every other request,
including WebSockets, is proxied upstream only with a valid session; without one,
pages get an empty 404 and everything else a 401.
"""

import asyncio
import hashlib
import hmac
import logging
import os
import re
import secrets
import time
from contextlib import asynccontextmanager
from urllib.parse import urlsplit

import httpx
from fastapi import FastAPI, Request, WebSocket
from fastapi.responses import JSONResponse, RedirectResponse, Response, StreamingResponse
from starlette.background import BackgroundTask
from starlette.middleware.trustedhost import TrustedHostMiddleware
from websockets.asyncio.client import connect as ws_connect
from websockets.exceptions import ConnectionClosed, InvalidHandshake, InvalidURI

log = logging.getLogger("daksha.gateway")
ENV_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".env")


def _load_env_file(path: str) -> None:
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


_load_env_file(ENV_FILE)


def _env_secret(name: str) -> str:
    value = os.environ.get(name, "")
    if len(value) < 32:
        raise RuntimeError(
            f"{name} must be a random value of at least 32 characters. "
            f"Copy .env.example to {ENV_FILE} and fill it in (see the file)."
        )
    return value


SESSION_SECRET = _env_secret("SESSION_SECRET").encode()
# Comma-separated, so each device can have its own key and be revoked alone.
LAUNCH_KEYS = [k.strip().encode() for k in _env_secret("APP_LAUNCH_KEY").split(",") if k.strip()]
UPSTREAM_URL = os.environ.get("UPSTREAM_URL", "http://127.0.0.1:8101").rstrip("/")
COOKIE_NAME = os.environ.get("COOKIE_NAME", "daksha_session")
COOKIE_SECURE = os.environ.get("COOKIE_SECURE", "true").lower() not in ("0", "false", "no")
TICKET_TTL = int(os.environ.get("TICKET_TTL", "60"))
SESSION_TTL = int(os.environ.get("SESSION_TTL", str(8 * 3600)))
ALLOWED_HOSTS = [h.strip() for h in os.environ.get("ALLOWED_HOSTS", "*").split(",") if h.strip()]

GATE = "/_gate"
_MAX_FAILURES = 10  # bad launch keys per client per minute before answering 429

# Hop-by-hop headers, plus the ones the proxy sets itself.
_SKIP_HEADERS = {
    "connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "te", "trailer",
    "transfer-encoding", "upgrade", "host", "content-length", "cookie",
}
_WS_SKIP_HEADERS = _SKIP_HEADERS | {
    "sec-websocket-key", "sec-websocket-version", "sec-websocket-extensions",
    "sec-websocket-protocol",
}


class _Tokens:
    """Live tickets or sessions, kept as keyed hashes with their expiry times.

    Process-local: run the gateway with a single worker.
    """

    def __init__(self) -> None:
        self._expiry: dict[str, float] = {}

    @staticmethod
    def _digest(token: str) -> str:
        return hmac.new(SESSION_SECRET, token.encode(), hashlib.sha256).hexdigest()

    def add(self, token: str, ttl: int) -> None:
        now = time.monotonic()
        self._expiry = {k: t for k, t in self._expiry.items() if t > now}
        self._expiry[self._digest(token)] = now + ttl

    def valid(self, token: str) -> bool:
        return self._expiry.get(self._digest(token), 0) > time.monotonic()

    def pop(self, token: str) -> bool:
        """Removes [token]; true if it was live, so each ticket works once."""
        return self._expiry.pop(self._digest(token), 0) > time.monotonic()


tickets = _Tokens()
sessions = _Tokens()
_failures: dict[str, list[float]] = {}


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


logging.getLogger("uvicorn.access").addFilter(_RedactTickets())

client = httpx.AsyncClient(
    base_url=UPSTREAM_URL,
    # No read timeout: log pages stream for as long as they are open.
    timeout=httpx.Timeout(30, read=None),
    follow_redirects=False,
)


@asynccontextmanager
async def _lifespan(app: FastAPI):
    yield
    await client.aclose()


app = FastAPI(lifespan=_lifespan, docs_url=None, redoc_url=None, openapi_url=None)
if ALLOWED_HOSTS != ["*"]:
    app.add_middleware(TrustedHostMiddleware, allowed_hosts=ALLOWED_HOSTS)


def _client_ip(conn: Request | WebSocket) -> str:
    return conn.client.host if conn.client else "unknown"


def _rate_limited(ip: str) -> bool:
    now = time.monotonic()
    recent = [t for t in _failures.get(ip, []) if now - t < 60]
    if recent:
        _failures[ip] = recent
    else:
        _failures.pop(ip, None)
    return len(recent) >= _MAX_FAILURES


def _has_session(conn: Request | WebSocket) -> bool:
    session = conn.cookies.get(COOKIE_NAME)
    return bool(session) and sessions.valid(session)


def _safe_next(path: str) -> str:
    """Only same-site paths, so /_gate/entry can't redirect elsewhere."""
    if not path.startswith("/") or path.startswith("//") or "\\" in path:
        return "/"
    return path


def _upstream_cookies(conn: Request | WebSocket) -> str:
    """The request's cookies without the gateway session, which stays here."""
    return "; ".join(f"{k}={v}" for k, v in conn.cookies.items() if k != COOKIE_NAME)


def _upstream_path(conn: Request | WebSocket) -> str:
    path = conn.scope.get("raw_path") or conn.url.path.encode()
    query = conn.scope.get("query_string") or b""
    return (path + (b"?" + query if query else b"")).decode("latin-1")


@app.post(f"{GATE}/ticket")
async def create_ticket(request: Request) -> Response:
    ip = _client_ip(request)
    if _rate_limited(ip):
        return Response(status_code=429)
    key = request.headers.get("x-app-key", "").encode()
    # Check every key so the timing doesn't reveal which one nearly matched.
    if not sum(hmac.compare_digest(key, k) for k in LAUNCH_KEYS):
        _failures.setdefault(ip, []).append(time.monotonic())
        log.warning("rejected ticket request from %s", ip)
        return Response(status_code=401)
    ticket = secrets.token_urlsafe(32)
    tickets.add(ticket, TICKET_TTL)
    return JSONResponse(
        {"ticket": ticket, "expires_in": TICKET_TTL}, headers={"Cache-Control": "no-store"}
    )


@app.get(f"{GATE}/entry")
async def entry(request: Request, ticket: str = "", next: str = "/") -> Response:
    if not ticket or not tickets.pop(ticket):
        log.info("rejected ticket exchange from %s", _client_ip(request))
        return Response(status_code=403)
    # Replace any older session this browser had.
    old = request.cookies.get(COOKIE_NAME)
    if old:
        sessions.pop(old)
    session = secrets.token_urlsafe(32)
    sessions.add(session, SESSION_TTL)
    response = RedirectResponse(_safe_next(next), status_code=303)
    response.set_cookie(
        COOKIE_NAME,
        session,
        max_age=SESSION_TTL,
        httponly=True,
        secure=COOKIE_SECURE,
        samesite="lax",
        path="/",
    )
    response.headers["Cache-Control"] = "no-store"
    response.headers["Referrer-Policy"] = "no-referrer"
    return response


@app.get(f"{GATE}/session")
async def session_status(request: Request) -> Response:
    """204 while the session is valid, else 401; lets a page notice expiry."""
    return Response(status_code=204 if _has_session(request) else 401)


@app.post(f"{GATE}/logout")
async def logout(request: Request) -> Response:
    session = request.cookies.get(COOKIE_NAME)
    if session:
        sessions.pop(session)
    response = Response(status_code=204)
    response.delete_cookie(COOKIE_NAME, path="/", secure=COOKIE_SECURE, httponly=True, samesite="lax")
    return response


@app.api_route(
    "/{path:path}", methods=["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"]
)
async def proxy(request: Request, path: str) -> Response:
    if not _has_session(request):
        wants_page = request.method in ("GET", "HEAD") and "text/html" in request.headers.get(
            "accept", ""
        )
        return Response(status_code=404 if wants_page else 401)

    headers = [(k, v) for k, v in request.headers.items() if k not in _SKIP_HEADERS]
    if cookies := _upstream_cookies(request):
        headers.append(("cookie", cookies))
    # Keep the Host the browser used, as the web UI saw it before the gateway.
    headers += [
        ("host", request.headers.get("host", "")),
        ("x-forwarded-for", _client_ip(request)),
        ("x-forwarded-proto", request.url.scheme),
    ]
    upstream_request = client.build_request(
        request.method, _upstream_path(request), headers=headers, content=await request.body()
    )
    try:
        upstream = await client.send(upstream_request, stream=True)
    except httpx.HTTPError as e:
        log.error("upstream unreachable: %s", type(e).__name__)
        return Response(status_code=502)

    response = StreamingResponse(
        upstream.aiter_raw(),
        status_code=upstream.status_code,
        background=BackgroundTask(upstream.aclose),
    )
    for k, v in upstream.headers.multi_items():
        if k in _SKIP_HEADERS:
            continue
        if k == "location" and v.startswith(UPSTREAM_URL):
            v = v[len(UPSTREAM_URL):] or "/"
        response.raw_headers.append((k.encode("latin-1"), v.encode("latin-1")))
    return response


@app.websocket("/{path:path}")
async def proxy_websocket(websocket: WebSocket, path: str) -> None:
    if not _has_session(websocket):
        await websocket.close(code=1008)  # before accept, so the handshake gets a 403
        return

    upstream_url = "ws" + UPSTREAM_URL[len("http"):] + _upstream_path(websocket)
    headers = [(k, v) for k, v in websocket.headers.items() if k not in _WS_SKIP_HEADERS]
    if cookies := _upstream_cookies(websocket):
        headers.append(("cookie", cookies))
    subprotocols = websocket.scope.get("subprotocols") or None
    try:
        async with ws_connect(
            upstream_url,
            additional_headers=headers,
            subprotocols=subprotocols,
            max_size=None,
            open_timeout=10,
        ) as upstream:
            await websocket.accept(subprotocol=upstream.subprotocol)

            async def to_upstream() -> None:
                while True:
                    message = await websocket.receive()
                    if message["type"] == "websocket.disconnect":
                        return
                    if message.get("bytes") is not None:
                        await upstream.send(message["bytes"])
                    elif message.get("text") is not None:
                        await upstream.send(message["text"])

            async def to_client() -> None:
                async for message in upstream:
                    if isinstance(message, bytes):
                        await websocket.send_bytes(message)
                    else:
                        await websocket.send_text(message)

            tasks = [asyncio.create_task(to_upstream()), asyncio.create_task(to_client())]
            done, pending = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
            for task in pending:
                task.cancel()
            for task in done:
                if (e := task.exception()) and not isinstance(e, ConnectionClosed):
                    log.warning("websocket proxy error: %s", type(e).__name__)
            code = upstream.close_code or 1000
    except (OSError, InvalidHandshake, InvalidURI, asyncio.TimeoutError) as e:
        log.error("upstream websocket unreachable: %s", type(e).__name__)
        code = 1011
    try:
        await websocket.close(code=code)
    except RuntimeError:
        pass  # already closed by the client


if __name__ == "__main__":
    import socket

    import uvicorn

    host = os.environ.get("HOST", "127.0.0.1")
    port = int(os.environ.get("PORT", "8100"))
    name = socket.gethostname().split(".")[0].lower() if host in ("0.0.0.0", "::") else host
    print(f"Daksha gateway for {UPSTREAM_URL} reachable at:")
    print(f"    http://{name}{'.local' if name != host else ''}:{port}/")
    print(f"In the Daksha app, connect to: {name if port == 8100 else f'{name}:{port}'}", flush=True)
    # One worker: tickets and sessions live in this process's memory.
    uvicorn.run(app, host=host, port=port, server_header=False)
