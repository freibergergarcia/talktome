from fastapi.testclient import TestClient

from talktome_server.app import create_app

from .conftest import FakeEngine, make_wav


def upload(client, data, headers, **form):
    return client.post(
        "/v1/audio/transcriptions", headers=headers, files={"file": ("clip.wav", data, "audio/wav")}, data=form
    )


def test_health_needs_no_token(client):
    assert client.get("/health").json() == {"ok": True}


def test_rejects_missing_or_wrong_token(client):
    assert upload(client, make_wav(), {}).status_code == 401
    assert upload(client, make_wav(), {"Authorization": "Bearer nope"}).status_code == 401
    assert client.get("/v1/models").status_code == 401


def test_transcribes_json(client, auth, engine):
    response = upload(client, make_wav(), auth, model="whatever")
    assert response.status_code == 200
    assert response.json() == {"text": "hello world"}
    assert len(engine.calls[0]) == 16_000


def test_text_and_verbose_formats(client, auth):
    assert upload(client, make_wav(), auth, response_format="text").text == "hello world"
    verbose = upload(client, make_wav(seconds=2), auth, response_format="verbose_json").json()
    assert verbose["text"] == "hello world"
    assert verbose["duration"] == 2.0


def test_unknown_format_is_400(client, auth):
    assert upload(client, make_wav(), auth, response_format="srt").status_code == 400


def test_non_wav_is_415(client, auth):
    assert upload(client, b"ID3 not a wav", auth).status_code == 415


def test_too_short_skips_the_model(client, auth, engine):
    response = upload(client, make_wav(seconds=0.01), auth)
    assert response.json() == {"text": ""}
    assert engine.calls == []


def test_models_lists_the_loaded_model(client, auth):
    assert client.get("/v1/models", headers=auth).json()["data"][0]["id"] == "fake-model"


def test_no_token_configured_allows_anyone():
    open_client = TestClient(create_app(FakeEngine(), token=None))
    assert upload(open_client, make_wav(), {}).status_code == 200
