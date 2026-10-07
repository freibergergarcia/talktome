# talktome-server

Self-hosted speech-to-text for [TalkToMe](../README.md). Runs NVIDIA's
Parakeet TDT 0.6B v3 on Apple Silicon via
[parakeet-mlx](https://github.com/senstella/parakeet-mlx), behind an
OpenAI-compatible endpoint.

## Install

```sh
python3 -m venv ~/.local/share/talktome-server/venv
~/.local/share/talktome-server/venv/bin/pip install "./server[mlx]"
```

## Commands

| Command | What it does |
|---|---|
| `talktome-server serve` | Run in the foreground on `127.0.0.1:8766` |
| `talktome-server serve --host 0.0.0.0` | Listen on the network (requires a token) |
| `talktome-server token` | Print the bearer token, creating it on first use |
| `talktome-server install-agent [--host ...]` | Run at login via launchd |
| `talktome-server uninstall-agent` | Stop and remove the launch agent |

Options for `serve` and `install-agent`: `--host`, `--port` (default 8766),
`--model` (default `mlx-community/parakeet-tdt-0.6b-v3`).

Set `HF_HOME` before `install-agent` to reuse an existing Hugging Face cache.
The token can also come from the `TALKTOME_TOKEN` environment variable.

## API

```sh
curl http://localhost:8766/v1/audio/transcriptions \
  -H "Authorization: Bearer $(talktome-server token)" \
  -F file=@clip.wav -F model=any
# {"text": "..."}
```

| Endpoint | Auth | Notes |
|---|---|---|
| `POST /v1/audio/transcriptions` | Bearer | Multipart `file` (PCM WAV, any rate/channels), `response_format` = `json`, `text` or `verbose_json`. `model` and `language` are accepted and ignored: Parakeet detects the language. |
| `GET /v1/models` | Bearer | The loaded model |
| `GET /health` | None | `{"ok": true}` |

Only uncompressed WAV is accepted, so the server needs no ffmpeg.

## Logs

`~/Library/Logs/talktome-server.log` when installed as an agent. Each request
logs duration, loudness, inference time and transcript length, never the text.
