"""Parakeet's encoder: NVIDIA's FastConformer, in MLX on the GPU.

Written from NeMo's ConformerEncoder (nemo/collections/asr/modules and
parts/submodules in NeMo 3.0.0) for the configuration Parakeet TDT uses:
dw_striding subsampling by 8, relative-position attention without biases,
batch-norm convolution modules. Inference only, one clip at a time, so there
is no padding and no mask anywhere.

Weights are rearranged once at load, with the same arithmetic in fewer steps:
the batch norm folds into the depthwise convolution, the feed-forward halving
and the attention scale fold into weights, and the three attention projections
become one matrix multiply. Element-wise steps (Swish, the GLU gate) are
compiled into single GPU kernels.
"""

import math
from functools import partial

import mlx.core as mx
import numpy as np

EPS = 1e-5  # LayerNorm and BatchNorm


@partial(mx.compile, shapeless=True)
def _swish(x: mx.array) -> mx.array:
    return x * mx.sigmoid(x)


@partial(mx.compile, shapeless=True)
def _gate(values: mx.array, gates: mx.array) -> mx.array:
    return values * mx.sigmoid(gates)


class Encoder:
    def __init__(self, weights: dict[str, mx.array], *, layers: int, heads: int):
        self.heads = heads
        w = weights
        sub = "encoder.pre_encode."
        self._sub = [(w[f"{sub}conv.{i}.weight"], w[f"{sub}conv.{i}.bias"]) for i in (0, 2, 3, 5, 6)]
        channels = self._sub[0][0].shape[0]
        out = w[f"{sub}out.weight"]
        # NeMo flattens (channels, frequency); MLX's channels-last layout gives
        # (frequency, channels). Permute the weight's columns instead of the
        # activations.
        self._sub_out = out.reshape(out.shape[0], channels, -1).transpose(0, 2, 1).reshape(out.shape[0], -1)
        self._sub_out_bias = w[f"{sub}out.bias"]
        self.width = out.shape[0]
        self._layers = [_Layer(w, f"encoder.layers.{i}.", heads) for i in range(layers)]
        self._positions = mx.zeros((0, self.width))

    def __call__(self, mel: mx.array) -> mx.array:
        """[frames, n_mels] log-mel -> [ceil(frames / 8), width] encodings."""
        x = self._subsample(mel)
        positions = self._relative_positions(x.shape[1])
        for layer in self._layers:
            x = layer(x, positions)
        return x[0]

    def _subsample(self, mel: mx.array) -> mx.array:
        (w0, b0), (w1, b1), (w2, b2), (w3, b3), (w4, b4) = self._sub
        x = mel[None, :, :, None]  # [batch, time, frequency, channels]
        x = mx.maximum(mx.conv2d(x, w0, stride=2, padding=1) + b0, 0)
        x = mx.conv2d(x, w1, stride=2, padding=1, groups=x.shape[-1]) + b1
        x = mx.maximum(x @ w2.reshape(w2.shape[0], -1).T + b2, 0)
        x = mx.conv2d(x, w3, stride=2, padding=1, groups=x.shape[-1]) + b3
        x = mx.maximum(x @ w4.reshape(w4.shape[0], -1).T + b4, 0)
        return x.reshape(1, x.shape[1], -1) @ self._sub_out.T + self._sub_out_bias

    def _relative_positions(self, length: int) -> mx.array:
        """NeMo's RelPositionalEncoding: sinusoids for relative distances
        length-1 down to -(length-1), computed in float32 as NeMo does."""
        if self._positions.shape[0] < 2 * length - 1:
            longest = max(length, 1500)  # 1500 frames = 120 s, the longest chunk
            distance = np.arange(longest - 1, -longest, -1, dtype=np.float32)[:, None]
            rate = np.exp(np.arange(0, self.width, 2, dtype=np.float32) * np.float32(-math.log(10000.0) / self.width))
            table = np.zeros((len(distance), self.width), dtype=np.float32)
            table[:, 0::2] = np.sin(distance * rate)
            table[:, 1::2] = np.cos(distance * rate)
            self._positions = mx.array(table)
        centre = self._positions.shape[0] // 2
        return self._positions[centre - length + 1 : centre + length]


class _Layer:
    def __init__(self, w: dict[str, mx.array], p: str, heads: int):
        self.heads = heads
        self.norms = {
            name: (w[f"{p}norm_{name}.weight"], w[f"{p}norm_{name}.bias"])
            for name in ("feed_forward1", "self_att", "conv", "feed_forward2", "out")
        }
        # Feed-forward modules: x + 0.5 * FF(x). Halving is exact in floating
        # point, so it moves into the second weight for free.
        self.ff = [
            (w[f"{p}{name}.linear1.weight"], 0.5 * w[f"{p}{name}.linear2.weight"])
            for name in ("feed_forward1", "feed_forward2")
        ]

        a = f"{p}self_attn."
        width = w[f"{a}linear_q.weight"].shape[0]
        self.head_size = width // heads
        self.scale = 1.0 / math.sqrt(self.head_size)
        self.qkv = mx.concatenate([w[f"{a}linear_q.weight"], w[f"{a}linear_k.weight"], w[f"{a}linear_v.weight"]])
        # The position term enters the scores already multiplied by the scale.
        self.position = self.scale * w[f"{a}linear_pos.weight"]
        self.bias_u = w[f"{a}pos_bias_u"][None, :, None, :]
        self.bias_v = w[f"{a}pos_bias_v"][None, :, None, :]
        self.attention_out = w[f"{a}linear_out.weight"]

        c = f"{p}conv."
        self.pointwise1 = w[f"{c}pointwise_conv1.weight"].squeeze(1)
        self.pointwise2 = w[f"{c}pointwise_conv2.weight"].squeeze(1)
        # BatchNorm at inference is y = (x - mean) / sqrt(var + eps) * gamma + beta,
        # an affine map per channel, so it folds into the depthwise kernel.
        gain = w[f"{c}batch_norm.weight"] * mx.rsqrt(w[f"{c}batch_norm.running_var"] + EPS)
        self.depthwise = w[f"{c}depthwise_conv.weight"] * gain[:, None, None]
        self.depthwise_bias = w[f"{c}batch_norm.bias"] - w[f"{c}batch_norm.running_mean"] * gain
        self.kernel = self.depthwise.shape[1]

    def __call__(self, x: mx.array, positions: mx.array) -> mx.array:
        x = x + self._feed_forward(self._norm(x, "feed_forward1"), *self.ff[0])
        x = x + self._attention(self._norm(x, "self_att"), positions)
        x = x + self._convolution(self._norm(x, "conv"))
        x = x + self._feed_forward(self._norm(x, "feed_forward2"), *self.ff[1])
        return self._norm(x, "out")

    def _norm(self, x: mx.array, name: str) -> mx.array:
        weight, bias = self.norms[name]
        return mx.fast.layer_norm(x, weight, bias, EPS)

    @staticmethod
    def _feed_forward(x: mx.array, w1: mx.array, w2: mx.array) -> mx.array:
        return _swish(x @ w1.T) @ w2.T

    def _attention(self, x: mx.array, positions: mx.array) -> mx.array:
        """Transformer-XL attention as NeMo runs it with SDPA: content scores
        from (q + u) . k, position scores (q + v) . p passed in as an additive
        mask."""
        batch, length, width = x.shape
        heads, size = self.heads, self.head_size
        qkv = (x @ self.qkv.T).reshape(batch, length, 3, heads, size).transpose(2, 0, 3, 1, 4)
        q, k, v = qkv[0], qkv[1], qkv[2]
        p = (positions @ self.position.T).reshape(1, -1, heads, size).transpose(0, 2, 1, 3)
        scores = (q + self.bias_v) @ p.swapaxes(-1, -2)  # [batch, heads, length, 2 * length - 1]
        # NeMo's rel_shift: row i keeps columns (length - 1 - i) ... (2 * length - 2 - i),
        # so entry (i, j) is the score for relative distance i - j.
        span = 2 * length - 1
        scores = mx.as_strided(
            scores,
            shape=(batch, heads, length, length),
            strides=(heads * length * span, length * span, span - 1, 1),
            offset=length - 1,
        )
        out = mx.fast.scaled_dot_product_attention(q + self.bias_u, k, v, scale=self.scale, mask=scores)
        return out.transpose(0, 2, 1, 3).reshape(batch, length, width) @ self.attention_out.T

    def _convolution(self, x: mx.array) -> mx.array:
        x = x @ self.pointwise1.T
        half = x.shape[-1] // 2
        x = _gate(x[..., :half], x[..., half:])  # GLU
        x = mx.conv1d(x, self.depthwise, padding=self.kernel // 2, groups=half) + self.depthwise_bias
        return _swish(x) @ self.pointwise2.T
