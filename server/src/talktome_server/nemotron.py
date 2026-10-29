"""Nemotron 3.5 Transcribe on one thread: the optional, larger engine.

NVIDIA's speech LLM: an ASR encoder feeding a 30B mixture-of-experts
language model, of which about 4B parameters run per token. It runs through
mlx-audio's port, from a 4-bit MLX conversion of NVIDIA's release that
tools/convert_nemotron.py makes. It makes fewer errors than Parakeet, at a
fraction of the speed and several times the memory; README.md, "Nemotron",
has the measurements.

Like ParakeetEngine, one worker thread owns the model for its whole life,
which also serializes requests.
"""

import logging
import re
import time
from concurrent.futures import ThreadPoolExecutor

import numpy as np

from .audio import SAMPLE_RATE
from .engine import CACHE_LIMIT_BYTES, LONGEST_PIECE, MIN_SAMPLES, PAUSE_SEARCH, split_at_pauses

log = logging.getLogger("talktome")

# NVIDIA's instruction for FLEURS, its multilingual benchmark (model card,
# "All Evaluated Prompts"): every word as spoken, fillers included, numbers
# in their standard written form. The card's "clean written transcript"
# wording leaves fillers out, but on FLEURS Portuguese it also dropped the
# article from 6 of the 31 sentences that begin with "Um" or "Uma" ("Um
# curry é..." became "Curry é...").
INSTRUCTION = (
    "Audio transcription. Language: as spoken, in its standard writing system. "
    "Wording: verbatim, including fillers and repetitions. Formatting: "
    "punctuation and capitalization; numbers in their standard written form. "
    "Output: transcript only."
)
# A language model can fall into a loop, repeating a phrase until it runs out
# of tokens. Each piece may write tokens in proportion to its length: on
# LibriSpeech and FLEURS the model never needed more than 6 per second of
# audio, so 16 leaves room for fast speech, and a loop in a 60 s piece stops
# after 1,024 tokens instead of the 16,384 NVIDIA's evaluation allows.
BASE_TOKENS = 64
TOKENS_PER_SECOND = 16

# NVIDIA's cleanup for the loops that do happen, from the model card (adapted
# there from Qwen3-ASR, Apache-2.0): a character repeated over 20 times, or a
# stretch of text repeated 20 times or more, is kept once.
CHARACTER_LOOP = re.compile(r"(.)\1{20,}", re.DOTALL)
TEXT_LOOP = re.compile(r"(.{1,4096}?)\1{19,}", re.DOTALL)


def token_budget(samples: int) -> int:
    return BASE_TOKENS + TOKENS_PER_SECOND * samples // SAMPLE_RATE


def remove_loops(text: str) -> str:
    return TEXT_LOOP.sub(r"\1", CHARACTER_LOOP.sub(r"\1", text))


class NemotronEngine:
    min_samples = MIN_SAMPLES

    def __init__(self, model_id: str):
        self.model_id = model_id
        self._thread = ThreadPoolExecutor(max_workers=1, thread_name_prefix="mlx")
        self._thread.submit(self._load).result()

    def _load(self) -> None:
        import mlx.core as mx
        from mlx_audio.stt import load

        mx.set_cache_limit(CACHE_LIMIT_BYTES)
        # strict: a folder with missing weights fails here instead of running
        # with uninitialized layers.
        self._model = load(self.model_id, strict=True)

    def warm_up(self) -> None:
        """The first call compiles GPU kernels; pay that at boot instead of on
        the first dictation."""
        started = time.perf_counter()
        # Straight to the model: transcribe() skips silence.
        self._thread.submit(self._piece, np.zeros(SAMPLE_RATE, dtype=np.float32)).result()
        log.info("model %s warm in %dms", self.model_id, round((time.perf_counter() - started) * 1000))

    def transcribe(self, samples: np.ndarray, languages: frozenset[str] | None = None) -> str:
        """`languages` is ignored: the model identifies the language itself, and
        the alphabet guard in languages.py works on Parakeet's vocabulary."""
        return self._thread.submit(self._transcribe, samples).result()

    def _transcribe(self, samples: np.ndarray) -> str:
        # The model was trained on recordings of up to an hour; cutting at 60 s
        # anyway bounds the work of each pass, and a loop can only cost one piece.
        pieces = (samples[start:end] for start, end in split_at_pauses(samples, LONGEST_PIECE, PAUSE_SEARCH))
        # A mic that sends only zeros (a closed laptop's) still reaches the
        # server, and the model answers pure silence with words, from "Okay."
        # to a made-up sentence for 5 s, which TalkToMe would paste. Parakeet
        # returns nothing.
        texts = (self._piece(piece) for piece in pieces if piece.any())
        return " ".join(text for text in texts if text)

    def _piece(self, samples: np.ndarray) -> str:
        budget = token_budget(len(samples))
        result = self._model.generate(samples, prompt=INSTRUCTION, max_tokens=budget, temperature=0.0, top_p=1.0)
        if result.generation_tokens >= budget:
            log.warning("a %.1fs piece used all %d tokens: probably a loop", len(samples) / SAMPLE_RATE, budget)
        return remove_loops(result.text)
