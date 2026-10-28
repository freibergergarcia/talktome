from types import SimpleNamespace

import numpy as np

from talktome_server.nemotron import INSTRUCTION, NemotronEngine, remove_loops, token_budget

RATE = 16_000


def test_token_budget_grows_with_the_audio():
    assert token_budget(RATE) == 80
    assert token_budget(60 * RATE) == 1024


def test_loops_are_kept_once():
    assert remove_loops("Wait" + "!" * 30) == "Wait!"
    assert remove_loops("I said" + " the same thing" * 25 + ". The end.") == "I said the same thing. The end."


def test_ordinary_repetition_is_kept():
    text = "No, no, no. That is not what I said. " * 3
    assert remove_loops(text) == text


class FakeModel:
    """Stands in for mlx-audio's model: one canned transcript per call."""

    def __init__(self, texts):
        self.texts = iter(texts)
        self.calls = []

    def generate(self, samples, **options):
        self.calls.append((len(samples), options))
        return SimpleNamespace(text=next(self.texts), generation_tokens=5)


def fake_engine(monkeypatch, texts):
    model = FakeModel(texts)
    monkeypatch.setattr(NemotronEngine, "_load", lambda engine: setattr(engine, "_model", model))
    return NemotronEngine("folder"), model


def test_digital_silence_never_reaches_the_model(monkeypatch):
    engine, model = fake_engine(monkeypatch, ["Okay."])

    assert engine.transcribe(np.zeros(2 * RATE, dtype=np.float32)) == ""
    assert model.calls == []

    engine.warm_up()
    assert len(model.calls) == 1


def test_long_recording_is_transcribed_in_pieces(monkeypatch):
    engine, model = fake_engine(monkeypatch, ["First piece.", "", "Third" + " again" * 25])
    audio = (0.1 * np.random.default_rng(0).standard_normal(150 * RATE)).astype(np.float32)

    text = engine.transcribe(audio, languages=frozenset({"en"}))

    assert text == "First piece. Third again"
    assert sum(length for length, _ in model.calls) == len(audio)
    for length, options in model.calls:
        assert options == {"prompt": INSTRUCTION, "max_tokens": token_budget(length), "temperature": 0.0, "top_p": 1.0}
