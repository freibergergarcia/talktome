"""Audio decoding without ffmpeg.

The TalkToMe app uploads 16 kHz mono 16-bit WAV, which needs no resampling.
Other PCM WAVs are accepted and converted; compressed formats are not.
"""

import io
import wave

import numpy as np

SAMPLE_RATE = 16_000


class UnsupportedAudio(ValueError):
    """Raised for anything other than uncompressed PCM WAV."""


def decode_wav(data: bytes) -> np.ndarray:
    """Return mono float32 samples in [-1, 1] at 16 kHz."""
    try:
        with wave.open(io.BytesIO(data)) as wav:
            channels = wav.getnchannels()
            width = wav.getsampwidth()
            rate = wav.getframerate()
            frames = wav.readframes(wav.getnframes())
    except (wave.Error, EOFError) as error:
        raise UnsupportedAudio(f"expected a PCM WAV file: {error}") from error

    if width == 2:
        samples = np.frombuffer(frames, dtype="<i2").astype(np.float32) / 32768.0
    elif width == 4:
        samples = np.frombuffer(frames, dtype="<i4").astype(np.float32) / 2147483648.0
    elif width == 1:
        samples = (np.frombuffer(frames, dtype=np.uint8).astype(np.float32) - 128.0) / 128.0
    else:
        raise UnsupportedAudio(f"unsupported sample width: {width * 8} bits")

    if channels > 1:
        samples = samples.reshape(-1, channels).mean(axis=1)
    if rate != SAMPLE_RATE:
        samples = resample(samples, rate, SAMPLE_RATE)
    return samples


def resample(samples: np.ndarray, source_rate: int, target_rate: int) -> np.ndarray:
    """Linear-interpolation resampling. Good enough for speech recognition,
    which is robust to the mild aliasing this introduces."""
    if len(samples) == 0:
        return samples
    duration = len(samples) / source_rate
    target_length = max(1, round(duration * target_rate))
    positions = np.linspace(0, len(samples) - 1, target_length)
    return np.interp(positions, np.arange(len(samples)), samples).astype(np.float32)


def rms(samples: np.ndarray) -> float:
    return float(np.sqrt(np.mean(samples**2))) if len(samples) else 0.0
