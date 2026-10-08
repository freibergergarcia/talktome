"""Transcribe a reference set with talktome-server's Parakeet and compare
against NVIDIA NeMo's own transcripts of the same audio.

    python parity/compare.py reference.jsonl [--limit N] [--languages en,pt]

Each line of reference.jsonl: {"id", "audio" (path), "text" (human
transcript), "nemo" (NeMo's transcript)}; make_reference.py writes it.
Reports how many transcripts are identical to NeMo's, character for character,
and the word error rate of both against the human transcript.
"""

import argparse
import json
import os
import re
import sys
import time
import unicodedata

import mlx.core as mx
import numpy as np

from talktome_server.engine import PINNED_REVISIONS
from talktome_server.languages import parse_languages
from talktome_server.parakeet import Parakeet


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("reference")
    parser.add_argument("--model", default="mlx-community/parakeet-tdt-0.6b-v3")
    parser.add_argument("--limit", type=int)
    parser.add_argument("--languages")
    parser.add_argument("--show", type=int, default=5, help="print this many differences")
    args = parser.parse_args()

    rows = [json.loads(line) for line in open(args.reference)][: args.limit]
    revision = PINNED_REVISIONS.get(args.model)
    model = Parakeet.load(args.model, revision=revision)
    print(
        f"ours: {args.model}@{revision or 'latest'}, MLX {mx.__version__}, "
        f"MLX_ENABLE_TF32={os.environ.get('MLX_ENABLE_TF32', 'unset (TF32 on M5)')}; "
        f"reference: NeMo {rows[0].get('nemo_version', '?')} {rows[0].get('nemo_model', '')}"
    )
    languages = parse_languages(args.languages)
    model.transcribe(np.zeros(16_000, dtype=np.float32))  # compile kernels before timing

    same = 0
    errors = {"ours": 0, "nemo": 0}
    words = 0
    audio_seconds = compute_seconds = 0.0
    shown = 0
    for row in rows:
        samples = read_audio(row["audio"])
        started = time.perf_counter()
        ours = model.text(model.transcribe(samples, languages))
        compute_seconds += time.perf_counter() - started
        audio_seconds += len(samples) / 16_000
        same += ours == row["nemo"]
        reference = normalize(row["text"])
        words += len(reference)
        errors["ours"] += edit_distance(reference, normalize(ours))
        errors["nemo"] += edit_distance(reference, normalize(row["nemo"]))
        if ours != row["nemo"] and shown < args.show:
            shown += 1
            print(f"{row['id']}\n  nemo: {row['nemo']}\n  ours: {ours}", file=sys.stderr)

    print(f"{len(rows)} clips, {audio_seconds / 60:.1f} min of audio")
    print(f"identical to NeMo: {same}/{len(rows)} ({100 * same / len(rows):.2f}%)")
    print(f"WER ours {100 * errors['ours'] / words:.2f}%  NeMo {100 * errors['nemo'] / words:.2f}%")
    per_clip = 1000 * compute_seconds / len(rows)
    print(f"speed: {audio_seconds / compute_seconds:.0f}x real time ({per_clip:.1f} ms per clip)")


def read_audio(path: str) -> np.ndarray:
    import soundfile  # FLAC and float WAV, which the standard library cannot read

    data, rate = soundfile.read(path, dtype="float32")
    assert rate == 16_000, f"{path}: {rate} Hz, expected 16 kHz"
    return data if data.ndim == 1 else data.mean(axis=1)


def normalize(text: str) -> list[str]:
    """Lowercase words with punctuation removed; accented letters stay.
    Deliberately simple: both systems are scored the same way."""
    text = unicodedata.normalize("NFC", text.lower())
    return re.sub(r"[^\w\s']|_", " ", text).split()


def edit_distance(a: list[str], b: list[str]) -> int:
    row = list(range(len(b) + 1))
    for i, word in enumerate(a, 1):
        previous, row[0] = row[0], i
        for j, other in enumerate(b, 1):
            previous, row[j] = row[j], min(row[j] + 1, row[j - 1] + 1, previous + (word != other))
    return row[-1]


if __name__ == "__main__":
    main()
