"""Parakeet via parakeet-mlx, pinned to one thread.

MLX streams are per-thread: a model loaded on one thread cannot run on
another. One worker thread owns the model for its whole life, which also
serializes requests.
"""

import logging
import time
from concurrent.futures import ThreadPoolExecutor

import numpy as np

from .audio import SAMPLE_RATE

log = logging.getLogger("talktome")

DEFAULT_MODEL = "mlx-community/parakeet-tdt-0.6b-v3"
# Push-to-talk clips are short; longer audio is split the same way
# parakeet-mlx's own transcribe() does it, so memory stays flat.
CHUNK_SECONDS = 120.0
OVERLAP_SECONDS = 15.0


class ParakeetEngine:
    def __init__(self, model_id: str = DEFAULT_MODEL):
        self.model_id = model_id
        self._thread = ThreadPoolExecutor(max_workers=1, thread_name_prefix="mlx")
        self._thread.submit(self._load).result()

    def _load(self) -> None:
        from parakeet_mlx import from_pretrained
        from parakeet_mlx.parakeet import DecodingConfig

        self._model = from_pretrained(self.model_id)
        self._decoding = DecodingConfig()

    @property
    def min_samples(self) -> int:
        """Below one STFT window there is nothing to decode."""
        return self._model.preprocessor_config.win_length

    def warm_up(self) -> None:
        """First call compiles kernels and builds the mel filterbank; pay
        that at boot instead of on the first dictation."""
        started = time.perf_counter()
        self.transcribe(np.zeros(SAMPLE_RATE, dtype=np.float32))
        log.info("model %s warm in %dms", self.model_id, round((time.perf_counter() - started) * 1000))

    def transcribe(self, samples: np.ndarray) -> str:
        return self._thread.submit(self._transcribe, samples).result()

    def _transcribe(self, samples: np.ndarray) -> str:
        import mlx.core as mx
        from parakeet_mlx.alignment import (
            merge_longest_common_subsequence,
            merge_longest_contiguous,
            sentences_to_result,
            tokens_to_sentences,
        )
        from parakeet_mlx.audio import get_logmel

        model, decoding = self._model, self._decoding
        args = model.preprocessor_config
        # get_logmel expects float32: it views the complex STFT as the input dtype.
        audio = mx.array(samples.astype(np.float32))

        if len(samples) / SAMPLE_RATE <= CHUNK_SECONDS:
            return model.generate(get_logmel(audio, args), decoding_config=decoding)[0].text.strip()

        chunk = int(CHUNK_SECONDS * SAMPLE_RATE)
        overlap = int(OVERLAP_SECONDS * SAMPLE_RATE)
        tokens = []
        for start in range(0, len(audio), chunk - overlap):
            end = min(start + chunk, len(audio))
            if end - start < args.hop_length:
                break
            result = model.generate(get_logmel(audio[start:end], args), decoding_config=decoding)[0]
            offset = start / SAMPLE_RATE
            for sentence in result.sentences:
                for token in sentence.tokens:
                    token.start += offset
                    token.end = token.start + token.duration
            if not tokens:
                tokens = result.tokens
                continue
            try:
                tokens = merge_longest_contiguous(tokens, result.tokens, overlap_duration=OVERLAP_SECONDS)
            except RuntimeError:
                tokens = merge_longest_common_subsequence(tokens, result.tokens, overlap_duration=OVERLAP_SECONDS)
        return sentences_to_result(tokens_to_sentences(tokens, decoding.sentence)).text.strip()
