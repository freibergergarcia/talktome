"""Regenerate tests/fixtures/nemo_log_mel.npz with NVIDIA NeMo.

    pip install "nemo_toolkit[asr]"   # in a separate environment
    python make_mel_fixture.py ../tests/fixtures/nemo_log_mel.npz

Runs NeMo's own preprocessor, built from the model's config, on three short
synthetic signals. The inputs are stored next to the outputs so the test does
not depend on any random number generator.
"""

import sys

import numpy as np
import torch
from make_reference import load_model  # same pinned checkpoint


def main() -> None:
    preprocessor = load_model().preprocessor.eval()
    rng = np.random.default_rng(7)
    t = np.arange(9_600) / 16_000
    voice = 0.3 * np.sin(2 * np.pi * (120 * t + 900 * t**2)) * (1 + 0.5 * np.sin(2 * np.pi * 3 * t))
    voice += 0.02 * rng.standard_normal(len(t))
    signals = {
        "normal": voice.astype(np.float32),
        "quiet": (voice * 0.003).astype(np.float32),  # about 50 dB down
        "odd_length": (0.1 * rng.standard_normal(7_777)).astype(np.float32),
    }
    out = {}
    with torch.no_grad():
        for name, x in signals.items():
            mel, length = preprocessor(input_signal=torch.from_numpy(x)[None], length=torch.tensor([len(x)]))
            frames = int(length[0])
            out[f"{name}_samples"] = x
            out[f"{name}_mel"] = mel[0, :, :frames].T.numpy().astype(np.float32)  # [frames, n_mels]
    np.savez_compressed(sys.argv[1], **out)


if __name__ == "__main__":
    main()
