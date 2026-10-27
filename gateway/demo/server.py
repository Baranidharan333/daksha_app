"""Demo robot web UI that stands in for the real dashboard behind the gateway.

Run it on a localhost-only port and point the gateway's UPSTREAM_URL at it:

    uvicorn server:app --app-dir demo --host 127.0.0.1 --port 8101

It has no access control of its own; the gateway in front of it provides that.
"""

import asyncio
import time
from pathlib import Path

from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.responses import FileResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles

HERE = Path(__file__).parent
# The page scripts every gated UI includes (daksha-config.js, daksha-session.js).
PAGE_SCRIPTS = HERE.parent.parent / "webpage" / "static"
app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)
app.mount("/static", StaticFiles(directory=PAGE_SCRIPTS), name="static")


@app.get("/")
async def index() -> FileResponse:
    return FileResponse(HERE / "index.html")


@app.get("/logs")
async def logs_page() -> FileResponse:
    return FileResponse(HERE / "logs.html")


@app.get("/api/status")
async def status() -> dict:
    return {"robot": "demo", "battery": 87, "mode": "idle", "time": time.time()}


@app.get("/api/logs/stream")
async def log_stream() -> StreamingResponse:
    async def lines():
        n = 0
        while True:
            n += 1
            yield f"data: [{time.strftime('%H:%M:%S')}] demo log line {n}\n\n"
            await asyncio.sleep(1)

    return StreamingResponse(lines(), media_type="text/event-stream")


@app.websocket("/ws")
async def echo(ws: WebSocket) -> None:
    await ws.accept()
    try:
        while True:
            await ws.send_text(f"echo: {await ws.receive_text()}")
    except WebSocketDisconnect:
        pass
