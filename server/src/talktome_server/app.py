"""HTTP layer: an OpenAI-compatible transcription endpoint.

Speaking the same request shape as OpenAI's /v1/audio/transcriptions means
the TalkToMe app (and any other client) needs a single remote adapter for
this server and for hosted or self-hosted alternatives.
"""

import hmac
import logging
import time
from typing import Protocol

import numpy as np
from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.concurrency import run_in_threadpool
from fastapi.responses import JSONResponse, PlainTextResponse
from starlette.datastructures import Headers
from starlette.types import ASGIApp, Message, Receive, Scope, Send

from . import __version__
from .audio import SAMPLE_RATE, AudioTooLong, UnsupportedAudio, decode_wav, rms
from .languages import parse_languages

log = logging.getLogger("talktome")

MAX_SECONDS = 15 * 60
# 15 minutes of 48 kHz stereo 16-bit WAV is ~170 MB; anything bigger is refused
# before it is read into memory.
MAX_UPLOAD_BYTES = 200 * 1024 * 1024


class Engine(Protocol):
    model_id: str
    min_samples: int

    def transcribe(self, samples: np.ndarray, languages: frozenset[str] | None = None) -> str: ...


class _BodyTooLarge(Exception):
    pass


class Gate:
    """Checks the token and the body size before anything reads the body.

    FastAPI parses multipart uploads (spooling files to disk) before route
    dependencies run, so a token check in a dependency would still let anyone
    on the network upload unlimited data. This ASGI middleware runs first:
    every path except /health needs the token, and bodies stop being read
    past `max_bytes`, whether or not Content-Length is declared.
    """

    def __init__(self, app: ASGIApp, token: str | None, max_bytes: int) -> None:
        self.app = app
        self.expected = f"Bearer {token}".encode() if token else None
        self.max_bytes = max_bytes

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":  # lifespan; there are no WebSocket routes
            await self.app(scope, receive, send)
            return
        # GET /health is unauthenticated on purpose: clients use it to check
        # reachability. It still goes through the size limit below.
        public = scope["path"] == "/health" and scope["method"] in ("GET", "HEAD")
        headers = Headers(scope=scope)
        sent = headers.get("authorization", "").encode()
        if self.expected and not public and not hmac.compare_digest(sent, self.expected):
            await JSONResponse({"detail": "missing or wrong bearer token"}, status_code=401)(scope, receive, send)
            return
        length = headers.get("content-length")
        if length is not None and (not length.isdigit() or int(length) > self.max_bytes):
            await JSONResponse({"detail": "upload too large"}, status_code=413)(scope, receive, send)
            return

        received = 0
        overflow = started = finished = False

        async def counted_receive() -> Message:
            nonlocal received, overflow
            message = await receive()
            if message["type"] == "http.request":
                received += len(message.get("body", b""))
                if received > self.max_bytes:
                    overflow = True
                    raise _BodyTooLarge
            return message

        async def guarded_send(message: Message) -> None:
            nonlocal started, finished
            if overflow and not started:
                return  # whatever the app makes of the aborted body, the gate answers 413
            started = started or message["type"] == "http.response.start"
            finished = finished or (message["type"] == "http.response.body" and not message.get("more_body", False))
            await send(message)

        try:
            await self.app(scope, counted_receive, guarded_send)
        except _BodyTooLarge:
            pass
        if overflow and not started:
            await JSONResponse({"detail": "upload too large"}, status_code=413)(scope, receive, send)
        elif overflow and not finished:
            # The app had already started answering: end that response rather
            # than leave the client waiting.
            await send({"type": "http.response.body", "body": b"", "more_body": False})


def create_app(engine: Engine, token: str | None) -> FastAPI:
    app = FastAPI(title="talktome-server", version=__version__)
    # Multipart overhead on top of the audio itself is a few hundred bytes.
    app.add_middleware(Gate, token=token, max_bytes=MAX_UPLOAD_BYTES + 64 * 1024)

    @app.get("/health")
    def health() -> dict:
        return {"ok": True}

    @app.get("/v1/models")
    def models() -> dict:
        return {"object": "list", "data": [{"id": engine.model_id, "object": "model", "owned_by": "local"}]}

    @app.post("/v1/audio/transcriptions")
    async def transcriptions(
        file: UploadFile = File(...),
        model: str | None = Form(None),  # accepted for compatibility; the server runs one model
        # ISO-639-1, or several comma-separated: tokens in other alphabets are ruled out.
        language: str | None = Form(None),
        response_format: str = Form("json"),
    ):
        if response_format not in ("json", "text", "verbose_json"):
            raise HTTPException(status_code=400, detail=f"unsupported response_format: {response_format}")
        data = await file.read(MAX_UPLOAD_BYTES + 1)
        if len(data) > MAX_UPLOAD_BYTES:
            raise HTTPException(status_code=413, detail="upload too large")
        try:
            samples = decode_wav(data, max_seconds=MAX_SECONDS)
        except AudioTooLong as error:
            raise HTTPException(status_code=413, detail=str(error)) from error
        except UnsupportedAudio as error:
            raise HTTPException(status_code=415, detail=str(error)) from error

        seconds = len(samples) / SAMPLE_RATE

        started = time.perf_counter()
        languages = parse_languages(language)
        text = (
            await run_in_threadpool(engine.transcribe, samples, languages) if len(samples) >= engine.min_samples else ""
        )
        inference_ms = round((time.perf_counter() - started) * 1000)
        # Log shape only, never the transcript: dictation can hold anything.
        # Loudness and length tell "mic captured silence" apart from "model
        # heard nothing useful".
        log.info("transcribed %.1fs (rms %.4f) in %dms -> %d chars", seconds, rms(samples), inference_ms, len(text))

        if response_format == "text":
            return PlainTextResponse(text)
        if response_format == "verbose_json":
            return {"text": text, "duration": round(seconds, 2), "inference_ms": inference_ms}
        return {"text": text}

    return app
