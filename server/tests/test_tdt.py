import numpy as np

from talktome_server.tdt import TDTDecoder

# A toy model small enough to reason about by hand: 4 tokens plus blank (id 4),
# durations [0, 1, 2]. All-zero LSTM weights keep the prediction network's
# output at zero, and an identity joint makes each frame's logits equal to the
# frame itself (after ReLU). So a frame is a one-hot "token, duration" choice.
TOKENS, BLANK, DURATIONS = 4, 4, [0, 1, 2]
WIDTH = TOKENS + 1 + len(DURATIONS)


def toy(max_symbols=3):
    zeros = np.zeros((4 * 2, 2), dtype=np.float32)
    return TDTDecoder(
        embed=np.ones((TOKENS + 1, 2), dtype=np.float32),
        lstm=[(zeros, zeros, np.zeros(8, dtype=np.float32))],
        pred=(np.zeros((WIDTH, 2), dtype=np.float32), np.zeros(WIDTH, dtype=np.float32)),
        out=(np.eye(WIDTH, dtype=np.float32), np.zeros(WIDTH, dtype=np.float32)),
        durations=DURATIONS,
        max_symbols=max_symbols,
    )


def frame(token, duration, runner_up=None):
    f = np.zeros(WIDTH, dtype=np.float32)
    f[token] = 2.0
    if runner_up is not None:
        f[runner_up] = 1.0
    f[TOKENS + 1 + DURATIONS.index(duration)] = 1.0
    return f


def test_follows_durations_and_nemo_limits():
    frames = np.stack(
        [
            frame(1, 0),  # token, stay: repeats until max_symbols (3), then moves on
            frame(BLANK, 0),  # blank with duration 0 still moves one frame
            frame(2, 2),  # token, jump two frames...
            frame(3, 1),  # ...so this one is never looked at
            frame(3, 1),
            frame(BLANK, 2),
        ]
    )
    assert toy().decode(frames) == [(1, 0), (1, 0), (1, 0), (2, 2), (3, 4)]


def test_only_kept_tokens_can_win():
    # Token 1 has the highest logit, but it is not kept: the best kept token
    # wins instead, exactly as if token 1 had a logit of minus infinity.
    frames = np.stack([frame(1, 1, runner_up=3), frame(BLANK, 1)])
    keep = np.array([True, False, True, True])
    assert toy().decode(frames) == [(1, 0)]
    assert toy().decode(frames, keep=keep) == [(3, 0)]


def test_blank_always_stays_possible():
    frames = np.stack([frame(1, 1, runner_up=BLANK), frame(BLANK, 1)])
    assert toy().decode(frames) == [(1, 0)]
    assert toy().decode(frames, keep=np.zeros(TOKENS, dtype=bool)) == []
