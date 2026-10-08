"""Median time to transcribe one clip, by clip length.

    python parity/speed.py reference.jsonl [--engine parakeet-mlx]

The clips are real speech: the reference set's audio joined end to end, cut
to 2, 10, 60 and 120 s. Each length runs once to warm up, then RUNS times;
the median is reported.
"""

import argparse
import json
import statistics
import time

import numpy as np
from compare import read_audio
from engines import ENGINES, MODEL, load

LENGTHS = (2, 10, 60, 120)
RUNS = 7


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("reference")
    parser.add_argument("--engine", choices=ENGINES, default="ours")
    parser.add_argument("--model", default=MODEL)
    args = parser.parse_args()

    pieces, needed = [], max(LENGTHS) * 16_000
    for line in open(args.reference):
        pieces.append(read_audio(json.loads(line)["audio"]))
        if sum(map(len, pieces)) >= needed:
            break
    audio = np.concatenate(pieces)
    if len(audio) < needed:
        parser.error(f"{args.reference} holds {len(audio) / 16_000:.0f} s of audio; speed.py needs {max(LENGTHS)} s")

    description, transcribe = load(args.engine, args.model)
    print(description)
    for seconds in LENGTHS:
        clip = audio[: seconds * 16_000]
        transcribe(clip)
        times = []
        for _ in range(RUNS):
            started = time.perf_counter()
            transcribe(clip)
            times.append(time.perf_counter() - started)
        print(f"{seconds:>4} s  {1000 * statistics.median(times):5.0f} ms")


if __name__ == "__main__":
    main()
