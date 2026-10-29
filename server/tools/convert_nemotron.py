"""Convert NVIDIA's Nemotron 3.5 Transcribe release into the 4-bit MLX folder
the nemotron engine loads.

    python tools/convert_nemotron.py OUTPUT_DIR

Needs the [mlx,nemotron] extras, 68 GB of disk for NVIDIA's weights (kept in
the Hugging Face cache) and 19 GB for the result. Downloads the pinned
revision, checks the weights' SHA-256, then runs mlx-audio's own convert()
with two patches that change no written byte:
- the release's CTC timestamp head, which the MLX port does not implement,
  is dropped before the strict load;
- each tensor is evaluated on its own before its shard is written, so memory
  holds one source tensor at a time rather than a whole shard's worth.

conversion.json in the output records the inputs and the SHA-256 of each
weights file written, so two conversions can be compared.
"""

import hashlib
import json
import shutil
import sys
import time
from importlib.metadata import version
from pathlib import Path

REPO = "nvidia/NVIDIA-Nemotron-3.5-Transcribe-30B-A4B"
REVISION = "ef905575a106fdad904f3b0ce661dccad654607d"
WEIGHTS_SHA256 = "03142dde5176c1d4df21ee829642745a1d670ea4d79e1a4684c64d53195acff2"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(1 << 24):
            digest.update(chunk)
    return digest.hexdigest()


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    output = Path(sys.argv[1]).expanduser()
    if output.exists():
        sys.exit(f"{output} already exists: choose a new folder")

    import mlx.core as mx
    from huggingface_hub import snapshot_download
    from mlx_audio.convert import convert
    from mlx_audio.stt.models.nemotron_transcribe import Model

    snapshot = Path(snapshot_download(REPO, revision=REVISION, ignore_patterns=["*.png"]))
    print("checking the weights' SHA-256", flush=True)
    if (found := sha256(snapshot / "model.safetensors")) != WEIGHTS_SHA256:
        sys.exit(f"model.safetensors has SHA-256 {found}, expected {WEIGHTS_SHA256}")

    dropped = []
    sanitize = Model.sanitize
    save_safetensors = mx.save_safetensors

    def without_ctc_timestamps(weights):
        dropped.extend(key for key in weights if key.startswith("ctc_timestamp."))
        return sanitize({key: value for key, value in weights.items() if not key.startswith("ctc_timestamp.")})

    def save_one_tensor_at_a_time(file, arrays, metadata=None):
        for value in arrays.values():
            mx.eval(value)
        save_safetensors(file, arrays, metadata=metadata)

    Model.sanitize = staticmethod(without_ctc_timestamps)
    mx.save_safetensors = save_one_tensor_at_a_time
    mx.set_cache_limit(2 << 30)

    started = time.perf_counter()
    convert(str(snapshot), str(output), quantize=True, q_group_size=64, q_bits=4, q_mode="affine", model_domain="stt")
    seconds = time.perf_counter() - started
    for name in ("LICENSE", "THIRD_PARTY_NOTICES.md"):
        shutil.copy(snapshot / name, output)

    names = json.loads((output / "model.safetensors.index.json").read_text())["weight_map"]
    record = {
        "source_repo": REPO,
        "source_revision": REVISION,
        "source_weights_sha256": WEIGHTS_SHA256,
        "mlx_audio_version": version("mlx-audio"),
        "mlx_version": mx.__version__,
        "quantization": json.loads((output / "config.json").read_text())["quantization"],
        "dropped_before_load": {"ctc_timestamp.*": len(dropped)},
        "quantized_modules": sum(name.endswith(".scales") for name in names),
        "seconds": round(seconds, 1),
        "peak_memory_gib": round(mx.get_peak_memory() / 2**30, 2),
        "sha256": {path.name: sha256(path) for path in sorted(output.glob("*.safetensors"))},
    }
    (output / "conversion.json").write_text(json.dumps(record, indent=2) + "\n")
    print(json.dumps(record, indent=2))


if __name__ == "__main__":
    main()
