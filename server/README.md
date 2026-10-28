# talktome-server

Self-hosted speech-to-text for [TalkToMe](../README.md). Runs NVIDIA's
Parakeet TDT 0.6B v3 on Apple Silicon behind an OpenAI-compatible endpoint,
or, optionally, NVIDIA's larger Nemotron 3.5 Transcribe (see
[Nemotron](#nemotron)).

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
  "talktome-server[mlx] @ git+https://github.com/freibergergarcia/talktome@v0.3.2#subdirectory=server"
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
`--engine` (`parakeet`, the default, or `nemotron`: see [Nemotron](#nemotron)),
`--model` (for Parakeet, default `mlx-community/parakeet-tdt-0.6b-v3`),
`--languages` (Parakeet only, e.g. `en,pt`: never write in another alphabet;
see API).

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
Nemotron ignores `language`.

## Logs

`~/Library/Logs/talktome-server.log` when installed as an agent. Each request
logs duration, loudness, inference time and transcript length, never the text.

## Nemotron

An optional, larger engine, for a Mac with memory to spare when accuracy
matters more than speed: NVIDIA's
[Nemotron 3.5 Transcribe](https://huggingface.co/nvidia/NVIDIA-Nemotron-3.5-Transcribe-30B-A4B),
a speech language model whose audio encoder feeds a 30B mixture-of-experts
language model, of which about 4B parameters run per token. `nemotron.py`
runs it through [mlx-audio](https://github.com/Blaizzy/mlx-audio)'s port,
from a 4-bit MLX conversion of NVIDIA's release that
`tools/convert_nemotron.py` makes.

Measured on the same Mac Studio (M5 Max), on the same clips as above; error
rates as `parity/compare.py` computes them, against the human transcripts:

| | Parakeet (default) | Nemotron, 4-bit |
|---|---|---|
| Error rate, short clips (English / Portuguese) | 2.16% / 4.95% | 1.68% / 4.49% |
| Error rate, 12 LibriSpeech chapters (3.4 min average) | 1.92% | 1.13% |
| Time for a 10 s clip | 40 ms | 342 ms |
| Time for a 60 s clip | 199 ms | 1,421 ms |
| GPU memory at peak, 60 s clip | 3.8 GB | 20.4 GB |
| Weights on disk | 2.5 GB | 19.3 GB |
| Languages | 25 European | 40 |
| Transcripts checked against the reference implementation | Yes, NeMo's | No: error rates only |

On these clips Nemotron makes about a fifth fewer errors than Parakeet in
English and a tenth fewer in Portuguese. It takes seven to nine times as
long and five times the memory, and two of its habits matter for dictation
(Limits, below): it writes Portuguese numbers as words more often, and it
answers a short press with nothing said with a word or two. Parakeet stays
the default.

### Setting it up

On the server Mac, with 87 GB of free disk: 68 GB for NVIDIA's release,
which stays in the Hugging Face cache, and 19 GB for the conversion.

```sh
venv/bin/pip install "./server[mlx,nemotron]"
venv/bin/python server/tools/convert_nemotron.py ~/models/nemotron-4bit
venv/bin/talktome-server install-agent --engine nemotron --model ~/models/nemotron-4bit
```

The conversion downloads the pinned revision of NVIDIA's weights, checks
their SHA-256, and runs mlx-audio's own converter; `conversion.json` in the
folder records what went in and the SHA-256 of what came out. With the
release already downloaded it took 41 s on the M5 Max, at a peak of 7.3 GiB,
and wrote the same bytes as an earlier conversion. `deploy-server.sh` passes
`--engine nemotron --model ...` through to `install-agent`, and installs the
extra; the folder must exist on the remote Mac first. Going back to Parakeet
is `install-agent` without `--engine`.

### How it runs

- Recordings are cut at pauses into pieces of at most 60 s, as for
  Parakeet. The model was trained on recordings of up to an hour; the cut
  bounds the time and memory of each pass.
- Each piece is transcribed with NVIDIA's instruction for FLEURS, its
  multilingual benchmark: verbatim, fillers and repetitions included,
  numbers in their standard written form. The model card's "clean written
  transcript" wording, which leaves fillers out, made more errors (1.93%
  against 1.68% in English, 4.55% against 4.49% in Portuguese) and dropped
  the article from 6 of the 31 Portuguese sentences that begin with "Um" or
  "Uma".
- A language model can loop, repeating a phrase until it runs out of tokens.
  A piece may write 64 tokens plus 16 per second of audio (1,024 for 60 s);
  on the test sets the model never wrote more than 6 per second. NVIDIA's
  loop cleanup then keeps one copy of a character repeated more than 20
  times, or of a stretch of text repeated 20 times or more. A piece that
  uses its whole budget is logged as a warning.
- A piece that is digital silence, all zeros, is not sent to the model. A
  mic that delivers only zeros (a closed laptop's) still reaches the server,
  and the model answers zeros with words, from "Okay." at 1 s to a made-up
  sentence at 5 s, which TalkToMe would paste. Parakeet returns nothing, and
  TalkToMe asks whether the right microphone is selected.
- The model identifies the language itself; `language` and `--languages`
  are ignored.
- One thread runs the model, so requests are served one at a time.

Limits:

- TalkToMe waits at most 15 s for an answer, and Nemotron needs about 1.5 s
  per minute of audio (3.1 s for 120 s), so dictations longer than about
  9 minutes time out and go to Apple's recognizer, if the fallback is on.
  The server still finishes the abandoned transcription before the next.
- Unlike Parakeet's, these transcripts are not checked against NVIDIA's own
  implementation, only scored. On LibriSpeech with the Open ASR
  Leaderboard's normalizer this conversion makes 1.45% errors where NVIDIA
  reports 1.09% (1.44% with NVIDIA's LibriSpeech instruction); whether the
  4-bit quantization or the port accounts for the difference is not
  settled.
- Of the 187 FLEURS sentences with digits in the reference, Nemotron wrote
  the numbers as words in 51 ("mil novecentos e oitenta e oito" for 1988),
  Parakeet in 8. Those 51 sentences hold 46% of Nemotron's Portuguese
  errors.
- A press with nothing said sends the mic's noise, and Nemotron answers it
  with a word or two, often in another language ("Okay.", "Sí.", "Семьдесят
  пять.", Russian for "seventy-five"), which TalkToMe pastes. On white noise
  at -80 to -40 dBFS and a 50 Hz hum, it wrote something for all 64 clips of
  2 s or less and for 5 of the 32 at 3 and 5 s; Parakeet for 15 of the 64
  and none of the longer ones. Asking in the instruction for nothing when
  there is no speech helped only from 2 s on, so the instruction stays as
  NVIDIA evaluated it.
