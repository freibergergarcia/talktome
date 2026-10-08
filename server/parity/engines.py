"""The engines the parity scripts measure, each called the way its server
calls it.

ours           talktome-server's ParakeetEngine: exact float32 unless
               MLX_ENABLE_TF32=1, recordings over 60 s cut at pauses.
parakeet-mlx   The library the server used before it had its own code,
               loaded and called as that server did: bfloat16 weights, one
               worker thread, one pass per clip up to 120 s. Only these
               scripts need it.

Both load the same snapshot of the weights.
"""

from collections.abc import Callable

import numpy as np

MODEL = "mlx-community/parakeet-tdt-0.6b-v3"
# The snapshot talktome_server.engine.PINNED_REVISIONS pins for MODEL.
REVISION = "ed2b7e8c15f9aaa0b5772e2efb986255eaef7e15"
ENGINES = ("ours", "parakeet-mlx")


def load(name: str, model: str = MODEL, languages: str | None = None) -> tuple[str, Callable[[np.ndarray], str]]:
    """A one-line description for reports, and a function from 16 kHz mono
    float32 samples to text. GPU kernels are compiled before it returns."""
    if name == "ours":
        return _ours(model, languages)
    if languages:
        raise ValueError(f"{name} has no language setting")
    return _parakeet_mlx(model)


def _ours(model: str, languages: str | None) -> tuple[str, Callable[[np.ndarray], str]]:
    import os

    from talktome_server.engine import PINNED_REVISIONS, ParakeetEngine
    from talktome_server.languages import parse_languages

    engine = ParakeetEngine(model, languages=parse_languages(languages))
    engine.warm_up()
    import mlx.core as mx  # after the engine has set MLX_ENABLE_TF32

    description = (
        f"ours: {model}@{PINNED_REVISIONS.get(model, 'latest')}, float32, MLX {mx.__version__}, "
        f"MLX_ENABLE_TF32={os.environ['MLX_ENABLE_TF32']}"
    )
    return description, engine.transcribe


def _parakeet_mlx(model: str) -> tuple[str, Callable[[np.ndarray], str]]:
    from concurrent.futures import ThreadPoolExecutor
    from importlib.metadata import version

    import mlx.core as mx
    from huggingface_hub import snapshot_download
    from mlx.utils import tree_flatten
    from parakeet_mlx import from_pretrained
    from parakeet_mlx.audio import get_logmel
    from parakeet_mlx.parakeet import DecodingConfig

    revision = REVISION if model == MODEL else None
    # from_pretrained takes no revision; a local folder holding the snapshot works.
    folder = snapshot_download(model, revision=revision, allow_patterns=["config.json", "model.safetensors"])
    # MLX streams are per thread: like the old server, one worker loads and runs it.
    worker = ThreadPoolExecutor(max_workers=1)
    lib = worker.submit(from_pretrained, folder).result()
    decoding = DecodingConfig()

    def run(samples: np.ndarray) -> str:
        mel = get_logmel(mx.array(samples.astype(np.float32)), lib.preprocessor_config)
        return lib.generate(mel, decoding_config=decoding)[0].text.strip()

    def transcribe(samples: np.ndarray) -> str:
        if len(samples) > 120 * 16_000:
            raise ValueError("the old server split clips over 120 s; not reproduced here")
        return worker.submit(run, samples).result()

    transcribe(np.zeros(16_000, dtype=np.float32))
    dtype = tree_flatten(lib.parameters())[0][1].dtype
    description = (
        f"parakeet-mlx {version('parakeet-mlx')}: {model}@{revision or 'latest'}, {dtype}, MLX {mx.__version__}"
    )
    return description, transcribe
