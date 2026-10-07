import numpy as np
import pytest

from talktome_server.audio import UnsupportedAudio, decode_wav, resample

from .conftest import make_wav


@pytest.mark.parametrize("width", [1, 2, 4])
def test_decodes_sample_widths(width):
    samples = decode_wav(make_wav(seconds=0.5, width=width, amplitude=0.5))
    assert samples.dtype == np.float32
    assert len(samples) == 8_000
    assert 0.45 < np.abs(samples).max() <= 1.0


def test_downmixes_stereo():
    assert len(decode_wav(make_wav(seconds=1, channels=2))) == 16_000


def test_resamples_to_16k():
    assert len(decode_wav(make_wav(seconds=1, rate=48_000))) == 16_000
    assert len(decode_wav(make_wav(seconds=1, rate=44_100))) == 16_000


def test_resample_empty():
    assert len(resample(np.array([], dtype=np.float32), 48_000, 16_000)) == 0


def test_rejects_non_wav():
    with pytest.raises(UnsupportedAudio):
        decode_wav(b"definitely not audio")
