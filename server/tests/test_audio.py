import numpy as np
import pytest

from talktome_server.audio import AudioTooLong, UnsupportedAudio, decode_wav, resample

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


def lying_header(rate=1, frames=10_000_000, channels=1):
    """A tiny WAV whose header declares a sample rate and length it never delivers."""
    import struct

    data = b"\x00\x00" * 100
    header = b"RIFF" + struct.pack("<I", 36 + len(data)) + b"WAVE"
    header += b"fmt " + struct.pack("<IHHIIHH", 16, 1, channels, rate, rate * 2 * channels, 2 * channels, 16)
    # Declared data size claims `frames` samples; the file holds only 100.
    header += b"data" + struct.pack("<I", frames * 2 * channels)
    return header + data


def test_rejects_absurd_sample_rate_before_resampling():
    # Before the fix this asked numpy for ~1.6e11 samples.
    with pytest.raises(UnsupportedAudio, match="sample rate"):
        decode_wav(lying_header(rate=1))


def test_rejects_declared_length_over_the_cap_before_decoding():
    with pytest.raises(AudioTooLong):
        decode_wav(lying_header(rate=16_000, frames=16_000 * 3600), max_seconds=900)


def test_rejects_too_many_channels():
    with pytest.raises(UnsupportedAudio, match="channel"):
        decode_wav(make_wav(seconds=0.1, channels=9))


def test_partial_trailing_frame_is_dropped():
    wav = make_wav(seconds=0.5, channels=2)
    assert len(decode_wav(wav[:-2])) == 7_999
