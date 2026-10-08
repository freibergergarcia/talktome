"""Log-mel features, computed the way NVIDIA NeMo computes them at inference.

Parakeet was trained on NeMo's FilterbankFeatures, so any difference here is a
difference in what the model hears. Each constant below names the NeMo
behaviour it reproduces (nemo/collections/asr/parts/preprocessing/features.py).
Plain NumPy in float64: it runs anywhere, and float64 keeps rounding well
below NeMo's own float32 error.
"""

import numpy as np

SAMPLE_RATE = 16_000
N_FFT = 512
HOP = 160  # 10 ms
WINDOW = 400  # 25 ms
N_MELS = 128
PREEMPHASIS = 0.97
LOG_FLOOR = 2.0**-24  # log_zero_guard_value; a larger floor flattens quiet speech
STD_FLOOR = 1e-5  # added to the per-feature standard deviation


def _hann() -> np.ndarray:
    # torch.hann_window(400, periodic=False), centred in the 512-sample frame
    # the way torch.stft pads a short window.
    window = np.hanning(WINDOW)
    left = (N_FFT - WINDOW) // 2
    return np.pad(window, (left, N_FFT - WINDOW - left))


def _mel_filterbank() -> np.ndarray:
    """librosa.filters.mel(sr=16000, n_fft=512, n_mels=128, norm="slaney"):
    triangles on the Slaney mel scale, each scaled to unit area."""

    def hz_to_mel(hz):
        hz = np.asarray(hz, dtype=np.float64)
        linear = hz / (200.0 / 3)
        log = 15.0 + np.log(np.maximum(hz, 1e-10) / 1000.0) / (np.log(6.4) / 27.0)
        return np.where(hz >= 1000.0, log, linear)

    def mel_to_hz(mel):
        linear = mel * (200.0 / 3)
        log = 1000.0 * np.exp((np.log(6.4) / 27.0) * (mel - 15.0))
        return np.where(mel >= 15.0, log, linear)

    edges = mel_to_hz(np.linspace(hz_to_mel(0.0), hz_to_mel(SAMPLE_RATE / 2), N_MELS + 2))
    bins = np.linspace(0, SAMPLE_RATE / 2, N_FFT // 2 + 1)
    widths = np.diff(edges)
    ramps = edges[:, None] - bins[None, :]
    rising = -ramps[:-2] / widths[:-1, None]
    falling = ramps[2:] / widths[1:, None]
    triangles = np.maximum(0.0, np.minimum(rising, falling))
    # librosa returns float32; NeMo multiplies with that float32 matrix.
    return (triangles * (2.0 / (edges[2:] - edges[:-2]))[:, None]).astype(np.float32).astype(np.float64)


_HANN = _hann()
_FILTERBANK = _mel_filterbank()


def log_mel(samples: np.ndarray) -> np.ndarray:
    """Mono 16 kHz samples -> normalized log-mel features, [frames, 128] float32.

    One frame per 10 ms hop (len // 160). Needs at least two frames: the
    per-feature normalization divides by frames - 1.
    """
    x = np.asarray(samples, dtype=np.float32).astype(np.float64)
    frames = len(x) // HOP
    x = np.concatenate([x[:1], x[1:] - PREEMPHASIS * x[:-1]])
    # torch.stft(center=True, pad_mode="constant"): zeros, not reflection.
    x = np.pad(x, N_FFT // 2)
    windows = np.lib.stride_tricks.sliding_window_view(x, N_FFT)[::HOP][:frames]
    spectrum = np.fft.rfft(windows * _HANN, axis=1)
    power = spectrum.real**2 + spectrum.imag**2  # |X|^2, not (|re| + |im|)^2
    mel = np.log(power @ _FILTERBANK.T + LOG_FLOOR)
    # per_feature normalization with the unbiased (n - 1) standard deviation.
    mel = (mel - mel.mean(axis=0)) / (mel.std(axis=0, ddof=1) + STD_FLOOR)
    return mel.astype(np.float32)
