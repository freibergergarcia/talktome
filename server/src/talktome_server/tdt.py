"""Parakeet's decoder: prediction network, joint network and greedy TDT search.

Plain NumPy on the CPU. Each step is a few matrix-vector products whose cost is
reading the weights from memory; a GPU would spend longer synchronizing than
computing. The search reproduces NVIDIA NeMo's default for this model
(greedy_batch, GreedyBatchedTDTLabelLoopingComputer) token for token.
"""

from typing import NamedTuple

import numpy as np

Matrix = np.ndarray


class Token(NamedTuple):
    id: int
    frame: int  # encoder frame where it was emitted


class TDTDecoder:
    """
    embed: [vocab + 1, E] token embeddings; the last row is blank, which
        doubles as the start symbol (NeMo's blank_as_pad).
    lstm: per layer (Wx [4H, in], Wh [4H, H], bias [4H]), gates in i, f, g, o order.
    pred: (W [J, H], b [J]) projects the LSTM output into the joint space.
    out: (W [vocab + 1 + len(durations), J], b) the joint's output layer.
    """

    def __init__(
        self,
        *,
        embed: Matrix,
        lstm: list[tuple[Matrix, Matrix, Matrix]],
        pred: tuple[Matrix, Matrix],
        out: tuple[Matrix, Matrix],
        durations: list[int],
        max_symbols: int = 10,
    ):
        self.blank = len(embed) - 1
        self.durations = np.asarray(durations)
        self.max_symbols = max_symbols
        (wx0, wh0, b0), *upper = lstm
        # The first layer's input term depends only on the previous token, so
        # it is a table lookup instead of a matrix-vector product per step.
        self._first_input = embed @ wx0.T + b0
        self._first_hidden = wh0
        # Upper layers: one product over [input; hidden] instead of two.
        self._upper = [(np.concatenate([wx, wh], axis=1), b) for wx, wh, b in upper]
        self._pred_w, self._pred_b = pred
        self._out_w, self._out_b = out
        self._outputs: dict[bytes, tuple[Matrix, Matrix, np.ndarray]] = {}

    def decode(self, frames: Matrix, keep: np.ndarray | None = None) -> list[Token]:
        """frames: [T, J] encoder output already projected by the joint's
        encoder layer. keep: optional boolean mask over the vocabulary; tokens
        outside it can never be emitted."""
        weights, bias, ids = self._output_rows(keep)
        n_labels = len(ids)  # kept tokens + blank
        frames = np.asarray(frames, dtype=np.float32)
        tokens: list[Token] = []
        state = self._initial_state()
        pred, state = self._predict(self.blank, state)
        t, last_t, run = 0, -1, 0
        while t < len(frames):
            logits = weights @ np.maximum(frames[t] + pred, 0) + bias
            token = int(ids[logits[:n_labels].argmax()])
            duration = int(self.durations[logits[n_labels:].argmax()])
            if token == self.blank:
                t += duration or 1  # blank must move forward, or it would repeat forever
                continue
            tokens.append(Token(token, t))
            pred, state = self._predict(token, state)
            run = run + 1 if t == last_t else 1
            last_t = t
            t += duration
            if duration == 0 and run >= self.max_symbols:
                t += 1
        return tokens

    def _output_rows(self, keep: np.ndarray | None) -> tuple[Matrix, Matrix, np.ndarray]:
        """Only the rows that can win: dropping a token's row is the same as
        giving it a logit of minus infinity, and it makes every step cheaper."""
        if keep is None:
            keep = np.ones(self.blank, dtype=bool)
        key = np.packbits(keep).tobytes()
        if key not in self._outputs:
            ids = np.append(np.flatnonzero(keep), self.blank)
            rows = np.concatenate([ids, np.arange(self.blank + 1, len(self._out_w))])
            self._outputs[key] = (
                np.ascontiguousarray(self._out_w[rows]),
                np.ascontiguousarray(self._out_b[rows]),
                ids,
            )
        return self._outputs[key]

    def _initial_state(self) -> list[tuple[np.ndarray, np.ndarray]]:
        size = self._first_hidden.shape[1]
        zeros = np.zeros(size, dtype=np.float32)
        return [(zeros, zeros)] * (1 + len(self._upper))

    def _predict(self, token: int, state: list[tuple[np.ndarray, np.ndarray]]):
        (h, c), *upper_state = state
        h, c = _lstm_cell(self._first_input[token] + self._first_hidden @ h, c)
        new_state = [(h, c)]
        for (w, b), (h_layer, c_layer) in zip(self._upper, upper_state, strict=True):
            h, c = _lstm_cell(w @ np.concatenate([h, h_layer]) + b, c_layer)
            new_state.append((h, c))
        return self._pred_w @ h + self._pred_b, new_state


def _lstm_cell(z: np.ndarray, c: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    size = len(c)
    gate = 1.0 / (1.0 + np.exp(-z))
    c = gate[size : 2 * size] * c + gate[:size] * np.tanh(z[2 * size : 3 * size])
    return gate[3 * size :] * np.tanh(c), c
