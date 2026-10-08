"""NVIDIA Parakeet TDT: audio in, tokens with timestamps out.

The weights are NVIDIA's, converted to safetensors by mlx-community; every
tensor is bit-identical to the original .nemo checkpoint. The code is ours:
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
from .languages import token_mask
from .tdt import TDTDecoder, Token

SUBSAMPLING = 8  # one encoder frame per 8 feature frames: 80 ms


class UnsupportedModel(ValueError):
    """The checkpoint is not a Parakeet TDT this code was written for."""


class Parakeet:
    def __init__(self, config: dict, weights: dict[str, mx.array]):
        _check(config)
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
        if languages not in self._masks:
            self._masks[languages] = token_mask(self.vocabulary, languages)
        return self._masks[languages]


def _space_before_punctuation(vocabulary: list[str]) -> re.Pattern:
    """NeMo's extract_punctuation_from_vocab: punctuation characters of
    ordinary tokens (not <special>, not word-initial)."""
    special = re.compile(r"^(\[.*\]|<.*>|\s*)$|^(##|▁)")
    tokens = [token for token in vocabulary if not special.match(token)]
    marks = {ch for token in tokens for ch in token if unicodedata.category(ch)[0] == "P"}
    return re.compile(r"(\s)(" + "|".join(re.escape(mark) for mark in sorted(marks)) + ")")


def _check(config: dict) -> None:
    """Fail at load, not with wrong transcripts, on a model this code does not
    implement."""
    encoder = config.get("encoder", {})
    expected = {
        "subsampling": "dw_striding",
        "subsampling_factor": SUBSAMPLING,
        "self_attention_model": "rel_pos",
        "conv_norm_type": "batch_norm",
        "xscaling": False,
        "use_bias": False,
        "untie_biases": True,
    }
    wrong = {key: encoder.get(key) for key, value in expected.items() if encoder.get(key) != value}
    if config.get("decoding", {}).get("model_type") != "tdt":
        wrong["decoding.model_type"] = config.get("decoding", {}).get("model_type")
    pre = config.get("preprocessor", {})
    if (pre.get("features"), pre.get("n_fft"), pre.get("normalize")) != (128, 512, "per_feature"):
        wrong["preprocessor"] = {key: pre.get(key) for key in ("features", "n_fft", "normalize")}
    if wrong:
        raise UnsupportedModel(f"not the Parakeet TDT architecture this code implements: {wrong}")
