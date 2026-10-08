"""Parakeet on one thread, with long recordings split at pauses.

MLX streams are per-thread: a model loaded on one thread cannot run on
another. One worker thread owns the model for its whole life, which also
serializes requests.
"""

import logging
import os
import time
from concurrent.futures import ThreadPoolExecutor

import numpy as np

from .audio import SAMPLE_RATE

log = logging.getLogger("talktome")

DEFAULT_MODEL = "mlx-community/parakeet-tdt-0.6b-v3"
# The snapshot whose 697 tensors were checked bit for bit against NVIDIA's
# .nemo checkpoint. Other models load from their latest revision.
PINNED_REVISIONS = {DEFAULT_MODEL: "ed2b7e8c15f9aaa0b5772e2efb986255eaef7e15"}

# Parakeet was trained on short utterances. Long recordings are cut into
# pieces of at most LONGEST_PIECE, each cut at the quietest moment of the
# piece's last PAUSE_SEARCH, so every piece starts and ends in a pause and
# no word is split. Cutting mid-speech at fixed points instead made some
# pieces lose their second half (see server/parity/README.md).
LONGEST_PIECE = 60 * SAMPLE_RATE
PAUSE_SEARCH = 15 * SAMPLE_RATE
# A clip shorter than one 25 ms analysis window has nothing to decode.
MIN_SAMPLES = 400
# MLX keeps freed GPU buffers for reuse; with a new clip length every request
# that cache grows without bound (20 GB after a day). Clips need far less.
CACHE_LIMIT_BYTES = 1 << 30


class ParakeetEngine:
    min_samples = MIN_SAMPLES

    def __init__(self, model_id: str = DEFAULT_MODEL, languages: frozenset[str] | None = None):
        self.model_id = model_id
        self.languages = languages
        self._thread = ThreadPoolExecutor(max_workers=1, thread_name_prefix="mlx")
        self._thread.submit(self._load).result()

    def _load(self) -> None:
        # On M5-class GPUs MLX runs float32 matrix products in TF32 by default:
        # ~30% faster encoder, but 1-2% of transcripts then differ from NVIDIA's
        # in a word or a comma (same error rate). Exact unless asked otherwise.
        os.environ.setdefault("MLX_ENABLE_TF32", "0")
        import mlx.core as mx

        from .parakeet import Parakeet

        mx.set_cache_limit(CACHE_LIMIT_BYTES)
        self._model = Parakeet.load(self.model_id, revision=PINNED_REVISIONS.get(self.model_id))

    def warm_up(self) -> None:
        """The first call compiles GPU kernels; pay that at boot instead of on
        the first dictation."""
        started = time.perf_counter()
        self.transcribe(np.zeros(SAMPLE_RATE, dtype=np.float32))
        log.info("model %s warm in %dms", self.model_id, round((time.perf_counter() - started) * 1000))

    def transcribe(self, samples: np.ndarray, languages: frozenset[str] | None = None) -> str:
        """`languages` overrides the server's default for this request."""
        return self._thread.submit(self._transcribe, samples, languages or self.languages).result()

    def _transcribe(self, samples: np.ndarray, languages: frozenset[str] | None) -> str:
        model = self._model
        texts = (
            model.text(model.transcribe(samples[start:end], languages))
            for start, end in split_at_pauses(samples, LONGEST_PIECE, PAUSE_SEARCH)
        )
        return " ".join(text for text in texts if text)


def split_at_pauses(samples: np.ndarray, longest: int, search: int) -> list[tuple[int, int]]:
    """(start, end) sample ranges covering `samples`, none longer than
    `longest`; each cut is at the centre of the quietest 300 ms within the
    last `search` samples before the limit."""
    pieces, start = [], 0
    while len(samples) - start > longest:
        cut = _quietest(samples, start + longest - search, start + longest)
        pieces.append((start, cut))
        start = cut
    pieces.append((start, len(samples)))
    return pieces


def _quietest(samples: np.ndarray, low: int, high: int, frame: int = 160, span: int = 30) -> int:
    """Centre of the `span` consecutive 10 ms frames with the least energy."""
    frames = (high - low) // frame
    energy = np.square(samples[low : low + frames * frame], dtype=np.float64).reshape(frames, frame).mean(axis=1)
    windowed = np.convolve(energy, np.ones(span) / span, mode="valid")
    return low + (int(windowed.argmin()) + span // 2) * frame
