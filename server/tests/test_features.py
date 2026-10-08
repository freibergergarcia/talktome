from pathlib import Path

import numpy as np
import pytest

from talktome_server.features import log_mel

# Made by NVIDIA NeMo 3.0.0's AudioToMelSpectrogramPreprocessor with the
# parakeet-tdt-0.6b-v3 config (see server/parity/make_mel_fixture.py).
NEMO = np.load(Path(__file__).parent / "fixtures" / "nemo_log_mel.npz")


# "quiet" is the same signal 50 dB down: the log floor matters most there.
@pytest.mark.parametrize("name", ["normal", "quiet", "odd_length"])
def test_matches_nemo(name):
    expected = NEMO[f"{name}_mel"]
    mel = log_mel(NEMO[f"{name}_samples"])
    assert mel.shape == expected.shape
    assert mel.dtype == np.float32
    # Features have unit variance, so 1e-3 is a thousandth of a standard
    # deviation; float32 rounding in NeMo itself accounts for ~6e-5.
    np.testing.assert_allclose(mel, expected, atol=1e-3, rtol=0)


def test_one_frame_per_hop():
    assert log_mel(np.zeros(16_000, dtype=np.float32)).shape == (100, 128)
