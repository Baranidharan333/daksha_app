# Daksha gate for the robot web page

These are the files the robot's web UI needs so that only the Daksha app can open it. This
follows the guide's original design: the web UI checks every request itself, with no proxy
in front.

| File | Goes in | What it does |
| --- | --- | --- |
| [`daksha_gate.py`](daksha_gate.py) | the web UI's Python server | ASGI middleware: serves `/_gate/*` and lets requests through only with a valid session |
| [`daksha.conf`](daksha.conf) | next to `.env` on the robot | `BROWSER_ACCESS`: open to any browser, or to the app only |
| [`.env.example`](.env.example) | copy to `.env` on the robot | Secrets, launch keys, cookie and lifetime settings |
| [`static/daksha-config.js`](static/daksha-config.js) | the web UI's static files | Page-side settings |
| [`static/daksha-session.js`](static/daksha-session.js) | the web UI's static files | Notices an expired session and has the app sign in again |
| [`main.py`](main.py), [`static/index.html`](static/index.html), [`static/logs.html`](static/logs.html) | just for trying it out | Example web UI using all of the above |

Use this **or** the [standalone gateway](../gateway/README.md), not both:

- **This folder:** the web UI is Python (FastAPI, Starlette, Django ASGI, Quart) and you can
  edit it. You get one process and one port.
- **The gateway:** the web UI is anything else, or you can't change it. The gateway sits in
  front as a proxy.

The protocol is the same, so the app works with either.

## Try the example

```bash
cd webpage
python3 -m venv .venv && . .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env        # put two random values in it (see the file)
python3 main.py             # http://127.0.0.1:8100
```

Give the app the key from `.env` and connect it to `localhost:8100`:

```bash
mkdir -p ~/.config/daksha
grep ^APP_LAUNCH_KEY= .env | cut -d= -f2 | cut -d, -f1 > ~/.config/daksha/app_key
chmod 600 ~/.config/daksha/app_key
```

In a normal browser, `http://127.0.0.1:8100/` is an empty page, and `/api/status` returns `401`.

## Add it to your web UI

### Server (Python)

Copy `daksha_gate.py` next to your app and add:

```python
from daksha_gate import DakshaGate, GateSettings, load_env_file

load_env_file("daksha.conf")
load_env_file(".env")
app.add_middleware(DakshaGate, settings=GateSettings.from_env())
```

Every route is gated: pages, APIs, static files, streams and WebSockets. Routes don't need
any changes. To leave a path open (for example a health check), list it in `PUBLIC_PATHS`.
Run with **one worker** (`--workers 1`), because tickets and sessions are kept in memory.

For Django, wrap the ASGI app: `application = DakshaGate(get_asgi_application(), GateSettings.from_env())`.

### Pages (HTML)

Copy `static/daksha-config.js` and `static/daksha-session.js` into your static folder and add
them to the `<head>` of every page, config first:

```html
<script src="/static/daksha-config.js"></script>
<script src="/static/daksha-session.js"></script>
```

The page code doesn't need any other changes. When the session runs out (8 hours, a gate
restart, or a logout), the next `fetch`/XHR `401` or refused WebSocket asks the app to sign
in again and reload the page. Pages can also use these:

```js
Daksha.inApp                 // true inside the Daksha app
Daksha.checkSession()        // Promise<boolean>
Daksha.logout()              // ends the session
Daksha.onExpired(() => {})   // e.g. close an EventSource or show a banner
```

`EventSource` retries by itself and hides `401`s, so close it in `Daksha.onExpired` (as
[`static/logs.html`](static/logs.html) does).

## Settings

**Access (`daksha.conf`):**

| Name | Default | Meaning |
| --- | --- | --- |
| `BROWSER_ACCESS` | `false` | `true`: any browser can open the web UI and the gate is off (`.env` secrets not needed). `false`: only the Daksha app can open it |

The app works in both modes: with the gate off it finds no `/_gate` and opens pages
directly. Restart the server after changing it.

**Server (`.env`):**

| Name | Default | Meaning |
| --- | --- | --- |
| `SESSION_SECRET` | — (required) | At least 32 random characters, different on each robot |
| `APP_LAUNCH_KEY` | — (required) | Launch keys the app may use, comma-separated, one per laptop |
| `COOKIE_SECURE` | `true` | Set `false` while the robot uses plain HTTP |
| `TICKET_TTL` | `60` | Seconds a ticket stays valid |
| `SESSION_TTL` | `28800` | Seconds a session lasts (8 hours) |
| `COOKIE_NAME` | `daksha_session` | Change it if two UIs share one host |
| `PUBLIC_PATHS` | empty | Path prefixes served without a session |
| `HOST`, `PORT` | `127.0.0.1`, `8100` | Used by `python3 main.py` |

**Page (`daksha-config.js`):**

| Name | Default | Meaning |
| --- | --- | --- |
| `gatePath` | `/_gate` | Where the gate's routes are |
| `sessionCheckSeconds` | `300` | How often an idle page checks its session (`0` turns it off) |
| `whenExpiredOutsideApp` | `none` | `reload` reloads the page outside the app when the session ends |
| `debug` | `false` | Logs session events to the console |

## Limits

These are the same as for the gateway:

- Anyone with access to a laptop can copy its launch key, so give each laptop its own key.
- On plain HTTP, anyone on the robots' network can see tickets and cookies. Use HTTPS with
  `COOKIE_SECURE=true` for real protection.
- Ending a session doesn't close WebSockets that are already open.
