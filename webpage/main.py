"""Example robot web UI with the Daksha gate built in.

    python3 main.py        (reads .env next to this file)

To add the gate to an existing FastAPI app, copy daksha_gate.py next to it and
add the three marked lines; the rest of this file is the example UI.
"""

import asyncio
import html
import os
import time
from pathlib import Path

from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.responses import FileResponse, HTMLResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles

from daksha_gate import (  # (1) import the gate
    DakshaGate,
    GateSettings,
    load_env_file,
    print_addresses,
)

HERE = Path(__file__).parent
STATIC = HERE / "static"
load_env_file(str(HERE / "daksha.conf"))  # (2) read the gate's settings
load_env_file(str(HERE / ".env"))

app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)
app.add_middleware(DakshaGate, settings=GateSettings.from_env())  # (3) gate every route
app.mount("/static", StaticFiles(directory=STATIC), name="static")


@app.get("/health")
async def health() -> dict:
    """Listed in PUBLIC_PATHS, so monitoring can reach it without a session."""
    return {"ok": True}


@app.get("/")
async def index() -> HTMLResponse:
    # UI_NAME tells copies apart, e.g. a navigation stand-in on another port.
    name = html.escape(os.environ.get("UI_NAME", "Robot dashboard"))
    return HTMLResponse((STATIC / "index.html").read_text().replace("Robot dashboard", name))


@app.get("/logs")
async def logs_page() -> FileResponse:
    return FileResponse(STATIC / "logs.html")


@app.get("/api/status")
async def status() -> dict:
    return {"robot": "example", "battery": 87, "mode": "idle", "time": time.time()}


@app.get("/api/logs/stream")
async def log_stream() -> StreamingResponse:
    async def lines():
        n = 0
        while True:
            n += 1
            yield f"data: [{time.strftime('%H:%M:%S')}] log line {n}\n\n"
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


if __name__ == "__main__":
    import uvicorn

    host = os.environ.get("HOST", "127.0.0.1")
    port = int(os.environ.get("PORT", "8100"))
    print_addresses(host, port)
    # One worker: tickets and sessions live in this process's memory.
    uvicorn.run(app, host=host, port=port, server_header=False)
