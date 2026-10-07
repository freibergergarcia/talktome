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
from fastapi import Depends, FastAPI, File, Form, HTTPException, Request, UploadFile
from fastapi.concurrency import run_in_threadpool
from fastapi.responses import PlainTextResponse

from . import __version__
from .audio import SAMPLE_RATE, AudioTooLong, UnsupportedAudio, decode_wav, rms

log = logging.getLogger("talktome")

MAX_SECONDS = 15 * 60
# 15 minutes of 48 kHz stereo 16-bit WAV is ~170 MB; anything bigger is refused
# before it is read into memory.
MAX_UPLOAD_BYTES = 200 * 1024 * 1024


class Engine(Protocol):
    model_id: str
    min_samples: int

    def transcribe(self, samples: np.ndarray) -> str: ...


def create_app(engine: Engine, token: str | None) -> FastAPI:
    app = FastAPI(title="talktome-server", version=__version__)

    def require_token(request: Request) -> None:
        if not token:
            return
        sent = request.headers.get("authorization", "")
        if not hmac.compare_digest(sent.encode(), f"Bearer {token}".encode()):
            raise HTTPException(status_code=401, detail="missing or wrong bearer token")

    @app.get("/health")
    def health() -> dict:
        # Unauthenticated on purpose: clients use it to check reachability.
        return {"ok": True}

    @app.get("/v1/models", dependencies=[Depends(require_token)])
    def models() -> dict:
        return {"object": "list", "data": [{"id": engine.model_id, "object": "model", "owned_by": "local"}]}

    @app.post("/v1/audio/transcriptions", dependencies=[Depends(require_token)])
    async def transcriptions(
        file: UploadFile = File(...),
        model: str | None = Form(None),  # accepted for compatibility; the server runs one model
        language: str | None = Form(None),  # Parakeet detects the language itself
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
        text = await run_in_threadpool(engine.transcribe, samples) if len(samples) >= engine.min_samples else ""
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
