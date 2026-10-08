# talktome-server

Self-hosted speech-to-text for [TalkToMe](../README.md). Runs NVIDIA's
Parakeet TDT 0.6B v3 on Apple Silicon behind an OpenAI-compatible endpoint.

## How it runs the model

The inference code is this package's own, written from NVIDIA NeMo's source
and checked against it:

| File | Part | Runs on |
|---|---|---|
| `features.py` | Log-mel front end, as NeMo's `FilterbankFeatures` | NumPy |
| `conformer.py` | FastConformer encoder | MLX (GPU) |
| `tdt.py` | Prediction network, joint, greedy TDT search | NumPy (CPU) |
| `parakeet.py` | Loads the weights, turns tokens into text | |
| `engine.py` | One model thread; splits recordings over 120 s | |

The weights are NVIDIA's, converted to safetensors by mlx-community
(`mlx-community/parakeet-tdt-0.6b-v3`, pinned to a revision whose tensors
hold the same float32 values as NVIDIA's `.nemo` checkpoint, with convolution
kernels in MLX's layout). `parity/` holds the scripts
that compare transcripts with NeMo's; see its README.

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
`--model` (default `mlx-community/parakeet-tdt-0.6b-v3`), `--languages`
(e.g. `en,pt`: never write in another alphabet; see API).

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
| `POST /v1/audio/transcriptions` | Bearer | Multipart `file` (PCM WAV, any rate/channels), `response_format` = `json`, `text` or `verbose_json`. `model` is accepted and ignored. `language` (ISO-639-1, or comma-separated like `en,pt`) overrides `--languages`. |
| `GET /v1/models` | Bearer | The loaded model |
| `GET /health` | None | `{"ok": true}` |

Only uncompressed WAV is accepted, so the server needs no ffmpeg.

Parakeet detects the language itself and has no way to be told one. What
`language` does is rule out tokens written in other alphabets: with `en,pt`
a short clip can no longer come back in Cyrillic or Greek. Languages that
share an alphabet (English and Portuguese) are still told apart by the model.

## Logs

`~/Library/Logs/talktome-server.log` when installed as an agent. Each request
logs duration, loudness, inference time and transcript length, never the text.
