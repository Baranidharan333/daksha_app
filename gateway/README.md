# Daksha gateway

A small FastAPI service that runs on each robot in front of its web UI. It makes the UI
open only from the Daksha app. Opening it in an ordinary browser gives an empty page. API
calls without a session get `401`, and WebSockets without a session are refused.

```
Daksha app ──POST /_gate/ticket (X-App-Key)──▶ gateway :8100 ──▶ web UI 127.0.0.1:8101
           ──GET  /_gate/entry?ticket=…  ──▶ session cookie, redirect to the page
           ──every other request + cookie ──▶ proxied (HTTP, streaming, WebSocket)
```

| Robot | Gateway listens on | Web UI moves to (localhost only) |
| --- | --- | --- |
| Dashboard (`s1.local`) | `0.0.0.0:8100` | `127.0.0.1:8101` |
| Navigation base (`base.local`) | `0.0.0.0:8000` | `127.0.0.1:8001` |

**The real web UI must stop listening on the network.** Otherwise anyone can skip the
gateway by using the UI's own port. Bind it to `127.0.0.1` and check from another
computer that `curl http://s1.local:8101/` fails.

## Gateway endpoints

| Route | Purpose |
| --- | --- |
| `POST /_gate/ticket` | Header `X-App-Key`. Returns `{"ticket", "expires_in"}`, `401` for a bad key, or `429` after 10 bad keys a minute |
| `GET /_gate/entry?ticket=…&next=/path` | Uses up the ticket (once, within `TICKET_TTL`), sets the `HttpOnly` session cookie and redirects to `next` |
| `GET /_gate/session` | `204` while the session is valid, else `401` |
| `POST /_gate/logout` | Ends the session |
| anything else | Proxied to `UPSTREAM_URL` when there is a valid session |

## Run the demo locally

`demo/` holds a stand-in robot UI: a page, a JSON API, a streaming log and a WebSocket.

```bash
cd gateway
python3 -m venv .venv && . .venv/bin/activate
pip install -r requirements.txt

# Terminal 1: the demo web UI, localhost only
uvicorn server:app --app-dir demo --host 127.0.0.1 --port 8101

# Terminal 2: the gateway
cp .env.example .env    # then put two random values in it (see the file)
set -a; . ./.env; set +a
uvicorn app:app --host 127.0.0.1 --port 8100 --workers 1
```

Give the app the same key and point it at the gateway:

```bash
mkdir -p ~/.config/daksha
grep ^APP_LAUNCH_KEY= .env | cut -d= -f2 | cut -d, -f1 > ~/.config/daksha/app_key
chmod 600 ~/.config/daksha/app_key
cd ../flutter/flutter_linux_browser && flutter run -d linux
```

In the app, connect to `localhost:8100`. Then check these:

```bash
curl -i -H 'Accept: text/html' http://127.0.0.1:8100/    # 404, empty body
curl -i http://127.0.0.1:8100/api/status                  # 401
curl -i -X POST -H 'X-App-Key: wrong' http://127.0.0.1:8100/_gate/ticket   # 401
```

## Add the gateway to the real web UI

1. Move the UI to `127.0.0.1:8101` (or `:8001` on the base).
2. Add these lines to the `<head>` of every page:

   ```html
   <script src="/static/daksha-config.js"></script>
   <script src="/static/daksha-session.js"></script>
   ```

   Serve both files from [`webpage/static/`](../webpage/static/). When the
   session runs out, any `401` or refused WebSocket makes the app sign in again and reload.
   Without the script, the app still recovers on the next page load or Reload, because
   it detects the gateway's empty page.
3. Pages must not depend on cookies from the other robot. `s1.local` and `base.local` are
   different sites, so `SameSite=Lax` keeps the dashboard from sending the base's session
   in `fetch` or an `<iframe>`. Open the base in its own tab instead (the Navigation button).
4. Don't use the `/_gate/` path or the `daksha_session` cookie name in the UI.

## Deploy on a robot

```bash
sudo mkdir -p /opt/daksha-gateway && sudo cp -r app.py requirements.txt /opt/daksha-gateway/
sudo python3 -m venv /opt/daksha-gateway/.venv
sudo /opt/daksha-gateway/.venv/bin/pip install -r /opt/daksha-gateway/requirements.txt
sudo cp .env.example /opt/daksha-gateway/.env && sudo chmod 600 /opt/daksha-gateway/.env
sudoedit /opt/daksha-gateway/.env            # new secrets for this robot; set UPSTREAM_URL
sudo cp daksha-gateway.service /etc/systemd/system/   # use --port 8000 on the base
sudo systemctl daemon-reload && sudo systemctl enable --now daksha-gateway
```

## Limits

- **The launch key can be copied.** Anyone who can read `~/.config/daksha/app_key`, or
  pull it from a build made with `--dart-define`, can get tickets. Give each laptop its own
  key (`APP_LAUNCH_KEY=key1,key2,…`), and remove a laptop's key to revoke it. The gateway
  keeps out casual access but doesn't prove the request came from an unmodified app.
- **Plain HTTP on the LAN.** Anyone on the network can see tickets and session cookies in
  transit. For real protection, put the robots behind HTTPS (for example nginx with a
  local CA) and set `COOKIE_SECURE=true`.
- **Tickets and sessions are kept in memory.** Restarting the gateway signs everyone out
  (the app signs in again by itself). Keep `--workers 1`.
- Ending a session doesn't close WebSockets that are already open.
