# Parity with NVIDIA NeMo

talktome-server runs Parakeet with its own code (`features.py`, `conformer.py`,
`tdt.py`). These scripts check that it transcribes exactly like NVIDIA's
reference implementation, NeMo, and measure it against parakeet-mlx, the
library the server used before.

| Script | Needs | Does |
|---|---|---|
| `make_reference.py` | `nemo_toolkit[asr]` | Transcribes a manifest with NeMo |
| `compare.py` | an engine, `soundfile` | Transcribes the same audio; counts identical transcripts, WER, speed |
| `speed.py` | an engine, `soundfile` | Median time per clip at 2, 10, 60 and 120 s |
| `engines.py` | | Loads `ours` (this package with `[mlx]`) or `parakeet-mlx` (that package), each as its server ran it |
| `make_mel_fixture.py` | `nemo_toolkit[asr]` | Regenerates `tests/fixtures/nemo_log_mel.npz` |

Install NeMo in its own virtual environment; it pulls in PyTorch and much more.
parakeet-mlx is needed only to measure it, and can share NeMo's environment.

These scripts write and print transcripts, which the server never does. Use
them only on public test sets, never on recordings of real dictation.

```sh
# manifest.jsonl: {"id": ..., "audio": "/path/16khz.flac", "text": "human transcript"} per line
python make_reference.py manifest.jsonl reference.jsonl              # NeMo env
python compare.py reference.jsonl                                    # talktome-server env
python compare.py reference.jsonl --engine parakeet-mlx              # parakeet-mlx env
python speed.py reference.jsonl [--engine parakeet-mlx]
```

Our engine is exact float32 by default; `MLX_ENABLE_TF32=1` measures the
faster TF32 mode instead (see below).

## Results (2026-10-08, Mac Studio M5 Max, NeMo 3.0.0, MLX 0.32.3)

Ours and parakeet-mlx 0.5.3 measured with these scripts, each engine as its
server runs it. Transcripts are compared character for character with NeMo's,
including punctuation and capitals.

| Set | Clips | Ours | Ours, TF32 | parakeet-mlx |
|---|---|---|---|---|
| LibriSpeech test-clean (English) | 2,620 | 2,620 (100%) | 2,597 (99.1%) | 1,889 (72.1%) |
| FLEURS pt_br test (Portuguese) | 919 | 919 (100%) | 901 (98.0%) | 699 (76.1%) |

Word error rate (`compare.py`'s plain normalization: lowercase, no
punctuation, both sides alike):

| Set | NeMo | Ours | parakeet-mlx |
|---|---|---|---|
| LibriSpeech test-clean | 2.16% | 2.16% | 2.16% |
| FLEURS pt_br test | 4.95% | 4.95% | 4.92% |

parakeet-mlx's transcripts differ from NeMo's in words on 222 English and
152 Portuguese clips, and only in punctuation or capitals on 577 more; on these
short clips (7 and 13 s on average) its error rate is the same. The gap shows
on longer dictations (below).

On M5-class GPUs MLX computes float32 matrix products in TF32 unless
`MLX_ENABLE_TF32=0`. Our server sets that by default; TF32 is faster at the
encoder and leaves the error rate unchanged, but a few transcripts then
differ from NeMo's by a word or a comma.

Median time per clip (`speed.py`):

| Clip | parakeet-mlx | Ours, exact | Ours, TF32 |
|---|---|---|---|
| 2 s | 39 ms | 19 ms | 15 ms |
| 10 s | 68 ms | 40 ms | 31 ms |
| 60 s | 311 ms | 199 ms | 144 ms |
| 120 s | 643 ms | 410 ms | 309 ms |

parakeet-mlx runs 120 s in one pass, as the old server did; ours cuts it at
pauses into pieces of at most 60 s (below). Over the whole sets ours runs at 223x (English)
and 289x (Portuguese) real time, parakeet-mlx at 138x and 182x. Our peak GPU
memory is ~1 GB higher (float32 weights instead of bfloat16): on Apple's M5
GPU float32 is both faster and exact.

## Long recordings

Parakeet was trained on short utterances. NeMo itself (batch 1, exact
features) sometimes stops emitting after a sentence ends when one pass covers
a long stretch that starts mid-speech: on one 30 s piece it transcribed the
first 16 s and then only blanks, exactly as our code does. Recordings longer
than 60 s are therefore cut at the quietest moment near each 60 s limit
(`engine.split_at_pauses`), normally a pause, so pieces start and end
between words like the utterances the model was trained on.

Twelve LibriSpeech chapters (5 min on average) joined back together,
compared with NeMo's transcripts of the individual utterances (one-off
scripts while switching engines, not the scripts here):

| Engine | WER |
|---|---|
| parakeet-mlx with its overlap-and-merge (before) | 1.33% |
| Ours, fixed 120 s windows with 16 s overlap, stitched | 4.62% |
| Ours, cut at pauses, pieces ≤ 120 s | 1.13% |
| **Ours, cut at pauses, pieces ≤ 60 s (shipped)** | **0.75%** |

At dictation lengths (one pass, whole consecutive utterances) NeMo-exact
features were as good or better than parakeet-mlx's at every length:
0.81 / 0.86 / 1.27 / 1.14% WER at ~20 / 40 / 60 / 90 s, against
0.83 / 1.02 / 1.41 / 1.60%.

## Memory

MLX keeps freed GPU buffers for reuse, and every new clip length allocates
new ones. 200 requests of 1-58 s (single process, M5 Max):

| | p50 latency | p99 latency | Buffer cache after |
|---|---|---|---|
| No cache limit (as before) | 3.60 ms per audio second | 22.3 | 35.7 GB |
| `mx.set_cache_limit(1 GB)` (now) | 3.43 ms per audio second | 15.5 | 1.1 GB |

The unlimited cache explains the previous server's process reaching 20 GB
after a day. With the limit the process holds 2.45 GB of weights plus at
most ~1.1 GB of cache (3.9 GB peak during a 60 s clip).
