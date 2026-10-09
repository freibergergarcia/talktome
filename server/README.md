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
| `engine.py` | One model thread; cuts recordings over 60 s at pauses | |

The weights are NVIDIA's, converted to safetensors by mlx-community
(`mlx-community/parakeet-tdt-0.6b-v3`, pinned to a revision whose tensors
hold the same float32 values as NVIDIA's `.nemo` checkpoint, with convolution
kernels in MLX's layout). `parity/` holds the scripts
that compare transcripts with NeMo's; see its README.

## Why not parakeet-mlx

Releases up to v0.1.1 ran Parakeet through
[parakeet-mlx](https://github.com/senstella/parakeet-mlx) 0.5.3. It is a
capable general-purpose library, but measured against NVIDIA NeMo, the
reference Parakeet was trained with, its transcripts drift, it is slower than
it needs to be on Apple's newer GPUs, and its GPU buffer cache grows without
limit (the server reached 20 GB after a day). Fixing that meant changing most
of the code we used, so the server now has its own.

Measured on a Mac Studio (M5 Max). Transcripts, short-clip error rates and
times come from `parity/compare.py` and `parity/speed.py`, each engine as its
server runs it; the 5-minute and memory figures from the measurements
described in [parity/README.md](parity/README.md); line counts from `wc -l`.

| | parakeet-mlx 0.5.3 | talktome-server |
|---|---|---|
| Transcripts identical to NeMo's (3,539 clips) | 73% | 100% |
| Error rate, short clips (English / Portuguese) | 2.16% / 4.92% | 2.16% / 4.95% |
| Error rate, 5-minute recordings | 1.33% | 0.75% |
| Time for a 10 s clip | 68 ms | 40 ms |
| Time for a 60 s clip | 311 ms | 199 ms |
| GPU memory | Grows without limit | 3.9 GB at most |
| Inference code | 3,633 lines (whole package) | 715 lines |

On short clips its error rate is the same as NeMo's: it makes different
mistakes, not more. The differences grow with length.

Where the differences come from:

| Part | parakeet-mlx 0.5.3 | talktome-server |
|---|---|---|
| Audio features | Six differences from NeMo (below), bfloat16 | NeMo's, computed in float64 |
| Weights | bfloat16 | float32: exact, and faster on M5 GPUs |
| Encoder | Layers run as stored | Normalization and constant scales folded into the weights at load; attention in one fused call |
| Decoder | Token by token on the GPU | NumPy on the CPU, no GPU round trip per token |
| Long recordings | 120 s windows, overlaps merged | Cut at pauses into pieces of at most 60 s |
| GPU buffer cache | Unbounded | Capped at 1 GB |
| Scope | TDT, RNNT and CTC models; beam search; streaming; CLI | Parakeet TDT, greedy decoding (NeMo's default) |
| Tests | None in its repository | Unit tests, plus `parity/` against NeMo |

The six feature differences: a periodic Hann window instead of a symmetric
one, left-aligned in the frame instead of centred; reflected instead of zero
padding at the edges; |re| + |im| instead of the power |X|²; a log floor of
1e-5 instead of 2⁻²⁴, which flattens quiet speech; and a biased instead of
unbiased standard deviation in the normalization.

## Install

On the Mac that will do the transcribing (Apple Silicon, Python 3.10+):

```sh
python3 -m venv ~/.local/share/talktome-server/venv
~/.local/share/talktome-server/venv/bin/pip install \
  "talktome-server[mlx] @ git+https://github.com/freibergergarcia/talktome@v0.3.0#subdirectory=server"
```

From a clone, install `"./server[mlx]"` instead.
`scripts/install-local-server.sh <version>` does what TalkToMe's "Set up
Parakeet on this Mac" does: a private, checksum-verified Python 3.12, the
server from that release, and a launch agent on localhost. Or deploy from
another Mac over SSH, which installs and starts it in one go:

```sh
scripts/deploy-server.sh my-server-mac --host 0.0.0.0
```

To update, run the same install with the new version tag (or
`deploy-server.sh` again), then restart with `talktome-server install-agent`
and the same options. The token and the downloaded model are kept. The app
and the server only share the API, so their versions do not need to match.

### Firewall

If the macOS firewall is on, it may silently drop connections to Python.
`install-agent` prints the exact program to allow; then on the server:

```sh
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --add <program>
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --unblockapp <program>
```

The path includes the Python version, so repeat this after upgrading Python.

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
| `POST /v1/audio/transcriptions` | Bearer | Multipart `file` (PCM WAV, any rate/channels), `response_format` = `json`, `text` or `verbose_json`. `model` is accepted and ignored. `language` (ISO-639-1, or comma-separated like `en,pt`) overrides `--languages` when it names a language the model knows. |
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
