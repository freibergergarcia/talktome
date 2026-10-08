"""NVIDIA Parakeet TDT: audio in, tokens with timestamps out.

The weights are NVIDIA's, converted to safetensors by mlx-community: every
tensor holds the same float32 values as the original .nemo checkpoint, with
convolution kernels reordered to MLX's channels-last layout. The code is ours:
features.py (log-mel), conformer.py (encoder, MLX on the GPU) and tdt.py
(decoder, NumPy on the CPU), each written from NVIDIA NeMo's source.
"""

import json
import re
import unicodedata
from pathlib import Path

import mlx.core as mx
import numpy as np

from .conformer import Encoder
from .features import log_mel
from .languages import alphabets, token_mask
from .tdt import TDTDecoder, Token

SUBSAMPLING = 8  # one encoder frame per 8 feature frames: 80 ms


class UnsupportedModel(ValueError):
    """The checkpoint is not a Parakeet TDT this code was written for."""


class Parakeet:
    def __init__(self, config: dict, weights: dict[str, mx.array]):
        check_config(config)
        encoder = config["encoder"]
        self.vocabulary: list[str] = config["joint"]["vocabulary"]
        self.encoder = Encoder(weights, layers=encoder["n_layers"], heads=encoder["n_heads"])
        self._joint_w, self._joint_b = weights["joint.enc.weight"], weights["joint.enc.bias"]

        def cpu(name: str) -> np.ndarray:
            return np.array(weights[name], dtype=np.float32)

        lstm = "decoder.prediction.dec_rnn.lstm"
        self.decoder = TDTDecoder(
            embed=cpu("decoder.prediction.embed.weight"),
            lstm=[
                (cpu(f"{lstm}.{i}.Wx"), cpu(f"{lstm}.{i}.Wh"), cpu(f"{lstm}.{i}.bias"))
                for i in range(config["decoder"]["prednet"]["pred_rnn_layers"])
            ],
            pred=(cpu("joint.pred.weight"), cpu("joint.pred.bias")),
            out=(cpu("joint.joint_net.2.weight"), cpu("joint.joint_net.2.bias")),
            durations=config["model_defaults"]["tdt_durations"],
            max_symbols=config["decoding"]["greedy"]["max_symbols"],
        )
        # Keyed by alphabet set, not by the requested codes: at most a handful
        # of entries whatever clients send.
        self._masks: dict[frozenset[str] | None, np.ndarray | None] = {}
        self._space_before_punctuation = _space_before_punctuation(self.vocabulary)

    @classmethod
    def load(cls, model: str, revision: str | None = None) -> "Parakeet":
        """A Hugging Face repo id (downloaded once, then cached) or a local
        directory holding config.json and model.safetensors."""
        if Path(model).is_dir():
            config_path, weights_path = Path(model) / "config.json", Path(model) / "model.safetensors"
        else:
            from huggingface_hub import hf_hub_download

            config_path = hf_hub_download(model, "config.json", revision=revision)
            weights_path = hf_hub_download(model, "model.safetensors", revision=revision)
        with open(config_path) as file:
            config = json.load(file)
        return cls(config, mx.load(str(weights_path)))

    def transcribe(self, samples: np.ndarray, languages: frozenset[str] | None = None) -> list[Token]:
        """Mono 16 kHz float samples, at least two 10 ms hops long. `languages`
        (ISO-639-1 codes) rules out tokens written in other alphabets."""
        encoded = self.encoder(mx.array(log_mel(samples)))
        frames = encoded @ self._joint_w.T + self._joint_b
        return self.decoder.decode(np.array(frames), keep=self._mask(languages))

    def text(self, tokens: list[Token]) -> str:
        """SentencePiece pieces joined, with the word marker as a space, then
        NeMo's decode_tokens_to_str_with_strip_punctuation: one space before
        a punctuation mark is removed ("first, 'Tis" -> "first,'Tis")."""
        text = "".join(self.vocabulary[token.id] for token in tokens).replace("▁", " ").strip()
        return self._space_before_punctuation.sub(r"\2", text)

    def _mask(self, languages: frozenset[str] | None) -> np.ndarray | None:
        key = alphabets(languages)
        if key not in self._masks:
            self._masks[key] = token_mask(self.vocabulary, languages)
        return self._masks[key]


def _space_before_punctuation(vocabulary: list[str]) -> re.Pattern:
    """NeMo's extract_punctuation_from_vocab: punctuation characters of
    ordinary tokens (not <special>, not word-initial)."""
    special = re.compile(r"^(\[.*\]|<.*>|\s*)$|^(##|▁)")
    tokens = [token for token in vocabulary if not special.match(token)]
    marks = {ch for token in tokens for ch in token if unicodedata.category(ch)[0] == "P"}
    return re.compile(r"(\s)(" + "|".join(re.escape(mark) for mark in sorted(marks)) + ")")


# Every configuration value the code depends on, by path in config.json.
# Layer counts, widths, kernel sizes and TDT durations are read from the
# config and weights instead.
_REQUIRED = {
    ("preprocessor", "sample_rate"): 16_000,
    ("preprocessor", "window_size"): 0.025,
    ("preprocessor", "window_stride"): 0.01,
    ("preprocessor", "window"): "hann",
    ("preprocessor", "features"): 128,
    ("preprocessor", "n_fft"): 512,
    ("preprocessor", "normalize"): "per_feature",
    ("preprocessor", "log"): True,
    ("preprocessor", "frame_splicing"): 1,
    ("preprocessor", "pad_to"): 0,
    ("encoder", "feat_in"): 128,
    ("encoder", "subsampling"): "dw_striding",
    ("encoder", "subsampling_factor"): SUBSAMPLING,
    ("encoder", "causal_downsampling"): False,
    ("encoder", "reduction"): None,
    ("encoder", "self_attention_model"): "rel_pos",
    ("encoder", "att_context_size"): [-1, -1],
    ("encoder", "xscaling"): False,
    ("encoder", "use_bias"): False,
    ("encoder", "untie_biases"): True,
    ("encoder", "conv_norm_type"): "batch_norm",
    ("encoder", "conv_context_size"): None,
    ("decoder", "blank_as_pad"): True,
    ("decoder", "normalization_mode"): None,
    ("joint", "jointnet", "activation"): "relu",
    ("decoding", "model_type"): "tdt",
}


def check_config(config: dict) -> None:
    """Fail at load, not with wrong transcripts, on a model this code does not
    implement."""
    wrong = []
    for path, expected in _REQUIRED.items():
        value = config
        for key in path:
            value = value.get(key) if isinstance(value, dict) else None
        if value != expected:
            wrong.append(f"{'.'.join(path)}={value!r} (expected {expected!r})")
    max_symbols = config.get("decoding", {}).get("greedy", {}).get("max_symbols")
    if not isinstance(max_symbols, int) or max_symbols < 1:
        wrong.append(f"decoding.greedy.max_symbols={max_symbols!r} (expected a positive integer)")
    if wrong:
        raise UnsupportedModel("not the Parakeet TDT architecture this code implements: " + ", ".join(wrong))
