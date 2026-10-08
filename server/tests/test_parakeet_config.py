import copy
import json
from pathlib import Path

import pytest

pytest.importorskip("mlx.core")  # parakeet.py needs MLX (Apple Silicon only)

from talktome_server.parakeet import UnsupportedModel, check_config  # noqa: E402

# The parts of parakeet-tdt-0.6b-v3's config.json that the code depends on.
V3 = json.loads((Path(__file__).parent / "fixtures" / "parakeet_v3_config.json").read_text())


def test_accepts_parakeet_v3():
    check_config(V3)


@pytest.mark.parametrize(
    "path,value",
    [
        (("preprocessor", "window_stride"), 0.02),
        (("preprocessor", "features"), 80),
        (("encoder", "att_context_size"), [128, 128]),
        (("encoder", "self_attention_model"), "rel_pos_local_attn"),
        (("encoder", "subsampling_factor"), 4),
        (("joint", "jointnet", "activation"), "tanh"),
        (("decoding", "model_type"), "rnnt"),
        (("decoding", "greedy", "max_symbols"), None),
        (("decoding", "greedy", "max_symbols"), True),
        (("encoder", "n_layers"), 0),
        (("encoder", "n_heads"), 3),
        (("decoder", "prednet", "pred_rnn_layers"), 0),
        (("model_defaults", "tdt_durations"), []),
        (("model_defaults", "tdt_durations"), [1, 2]),
    ],
)
def test_rejects_what_the_code_does_not_implement(path, value):
    config = copy.deepcopy(V3)
    *parents, key = path
    node = config
    for name in parents:
        node = node[name]
    node[key] = value
    with pytest.raises(UnsupportedModel, match=key):
        check_config(config)
