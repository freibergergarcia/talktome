from itertools import pairwise

import numpy as np

from talktome_server.engine import split_at_pauses

RATE = 16_000


def noise(seconds, level, seed=0):
    return (level * np.random.default_rng(seed).standard_normal(int(seconds * RATE))).astype(np.float32)


def test_short_recording_stays_whole():
    assert split_at_pauses(noise(30, 0.1), longest=60 * RATE, search=15 * RATE) == [(0, 30 * RATE)]


def test_cuts_in_the_pause():
    # 100 s of "speech" with one 0.5 s pause at 52.0-52.5 s. Pieces may be 60 s
    # long and the cut is searched in the last 15 s (45-60 s): it lands in the
    # pause, and the 47.5 s left over needs no further cut.
    audio = np.concatenate([noise(52, 0.1), noise(0.5, 0.001, seed=1), noise(47.5, 0.1, seed=2)])
    (first_start, cut), (second_start, end) = split_at_pauses(audio, longest=60 * RATE, search=15 * RATE)
    assert (first_start, second_start, end) == (0, cut, len(audio))
    assert 52.0 * RATE < cut < 52.5 * RATE


def test_long_recording_is_cut_repeatedly_within_bounds():
    audio = noise(200, 0.1)
    pieces = split_at_pauses(audio, longest=60 * RATE, search=15 * RATE)
    assert pieces[0][0] == 0 and pieces[-1][1] == len(audio)
    assert all(end == start for (_, end), (start, _) in pairwise(pieces))
    assert all(45 * RATE <= end - start <= 60 * RATE for start, end in pieces[:-1])
