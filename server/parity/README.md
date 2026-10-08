# Parity with NVIDIA NeMo

talktome-server runs Parakeet with its own code (`features.py`, `conformer.py`,
`tdt.py`). These scripts check that it transcribes exactly like NVIDIA's
reference implementation, NeMo, and show how fast it does it.

| Script | Needs | Does |
|---|---|---|
| `make_reference.py` | `nemo_toolkit[asr]` | Transcribes a manifest with NeMo |
| `compare.py` | this package, `mlx`, `soundfile` | Transcribes the same audio with our code; counts identical transcripts, WER, speed |
| `make_mel_fixture.py` | `nemo_toolkit[asr]` | Regenerates `tests/fixtures/nemo_log_mel.npz` |

Install NeMo in its own virtual environment; it pulls in PyTorch and much more.

```sh
# manifest.jsonl: {"id": ..., "audio": "/path/16khz.flac", "text": "human transcript"} per line
python make_reference.py manifest.jsonl reference.jsonl          # NeMo env
MLX_ENABLE_TF32=0 python compare.py reference.jsonl              # talktome-server env
```

## Results (2026-10-08, Mac Studio M5 Max, NeMo 3.0.0, MLX 0.32.3)

Transcripts compared character for character with NeMo's, including
punctuation and capitals.

| Set | Clips | Identical, exact float32 | Identical, TF32 | WER ours / NeMo |
|---|---|---|---|---|
| LibriSpeech test-clean (English) | 2,620 | 2,620 (100%) | 2,597 (99.1%) | 2.16% / 2.16% |
| FLEURS pt_br test (Portuguese) | 919 | 919 (100%) | 901 (98.0%) | 4.95% / 4.95% |

WER here uses `compare.py`'s plain normalization (lowercase, no
punctuation), applied to both sides alike.

On M5-class GPUs MLX computes float32 matrix products in TF32 unless
`MLX_ENABLE_TF32=0`. The server sets that by default; TF32 is ~25% faster at
the encoder and leaves the error rate unchanged, but a few transcripts then
differ from NeMo's by a word or a comma.

Median latency per clip (ms), against parakeet-mlx 0.5.3 as the server used it
before (bfloat16 weights):

| Clip | parakeet-mlx | Ours, exact | Ours, TF32 |
|---|---|---|---|
| 2 s | 30 | 18 | 16 |
| 10 s | 64 | 37 | 29 |
| 60 s | 309 | 197 | 142 |
| 120 s | 634 | 393 | 281 |

One pass per clip here; the server splits recordings over 60 s (below). Our
peak GPU memory is ~1 GB higher (float32 weights instead of bfloat16): on
Apple's M5 GPU float32 is both faster and exact.

## Long recordings

Parakeet was trained on short utterances. NeMo itself (batch 1, exact
features) sometimes stops emitting after a sentence ends when one pass covers
a long stretch that starts mid-speech: on one 30 s piece it transcribed the
first 16 s and then only blanks, exactly as our code does. Recordings longer
than 60 s are therefore cut at pauses (`engine.split_at_pauses`), so every
piece starts and ends in silence, like the utterances the model was trained on.

Twelve LibriSpeech chapters (5 min on average) joined back together,
compared with NeMo's transcripts of the individual utterances:

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
new ones. Without a limit, the previous server's process had reached 20 GB
after a day, most likely this cache. With
`mx.set_cache_limit(1 GB)`, 200 requests of 1-70 s stay at 2.45 GB of weights
plus ~1.1 GB of cache (3.9 GB peak).
