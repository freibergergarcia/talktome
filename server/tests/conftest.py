import io
import wave

import numpy as np
import pytest
from fastapi.testclient import TestClient

from talktome_server.app import create_app


class FakeEngine:
    model_id = "fake-model"
    min_samples = 400

    def __init__(self):
        self.calls = []
        self.languages = []

    def transcribe(self, samples, languages=None):
        self.calls.append(samples)
        self.languages.append(languages)
        return "hello world"


def make_wav(seconds=1.0, rate=16_000, channels=1, width=2, amplitude=0.3):
    t = np.arange(int(seconds * rate)) / rate
    tone = amplitude * np.sin(2 * np.pi * 440 * t)
    frames = np.repeat(tone[:, None], channels, axis=1).reshape(-1)
    if width == 2:
        raw = (frames * 32767).astype("<i2").tobytes()
    elif width == 1:
        raw = (frames * 127 + 128).astype(np.uint8).tobytes()
    else:
        raw = (frames * 2147483647).astype("<i4").tobytes()
    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as wav:
        wav.setnchannels(channels)
        wav.setsampwidth(width)
        wav.setframerate(rate)
        wav.writeframes(raw)
    return buffer.getvalue()


@pytest.fixture
def engine():
    return FakeEngine()


@pytest.fixture
def client(engine):
    return TestClient(create_app(engine, token="secret"))


@pytest.fixture
def auth():
    return {"Authorization": "Bearer secret"}
