"""Transcribe a manifest with NVIDIA NeMo, the reference implementation.

    pip install "nemo_toolkit[asr]"   # in a separate environment: it is large
    python make_reference.py manifest.jsonl reference.jsonl

manifest.jsonl: one {"id", "audio" (16 kHz file path), "text"} per line.
Writes the same lines with "nemo" (NeMo's transcript) added, the input for
compare.py. Runs on the CPU in float32 with the model's own decoding config
(greedy_batch TDT).
"""

import json
import logging
import sys
import warnings

warnings.filterwarnings("ignore")
logging.disable(logging.WARNING)

import nemo  # noqa: E402
import torch  # noqa: E402
from huggingface_hub import hf_hub_download  # noqa: E402
from nemo.collections.asr.models import ASRModel  # noqa: E402

MODEL = "nvidia/parakeet-tdt-0.6b-v3"
# The snapshot the published results were made with.
REVISION = "541d1f99c6b0c3cd0b11a95167540bb8edefd82b"


def load_model() -> ASRModel:
    checkpoint = hf_hub_download(MODEL, "parakeet-tdt-0.6b-v3.nemo", revision=REVISION)
    return ASRModel.restore_from(checkpoint, map_location="cpu").eval()


def main() -> None:
    manifest, output = sys.argv[1], sys.argv[2]
    rows = [json.loads(line) for line in open(manifest)]
    torch.set_grad_enabled(False)
    model = load_model()
    hypotheses = model.transcribe([row["audio"] for row in rows], batch_size=8, verbose=False)
    with open(output, "w") as out:
        for row, hypothesis in zip(rows, hypotheses, strict=True):
            row["nemo"] = hypothesis.text.strip()
            row["nemo_version"] = nemo.__version__
            row["nemo_model"] = f"{MODEL}@{REVISION}"
            out.write(json.dumps(row, ensure_ascii=False) + "\n")
    print(f"{len(rows)} clips -> {output}")


if __name__ == "__main__":
    main()
