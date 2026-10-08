import copy
import json
from pathlib import Path

import pytest

pytest.importorskip("mlx.core")  # parakeet.py needs MLX (Apple Silicon only)

from talktome_server.parakeet import UnsupportedModel, check_config  # noqa: E402

# The parts of parakeet-tdt-0.6b-v3's config.json that the code depends on.
V3 = json.loads((Path(__file__).parent / "fixtures" / "parakeet_v3_config.json").read_text())


def _config_with_vocabulary():
    config = copy.deepcopy(V3)  # the fixture leaves out the 8192-token vocabulary
    config["joint"]["vocabulary"] = ["▁a", "b"]
    return config


def test_accepts_parakeet_v3():
    check_config(_config_with_vocabulary())


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
        (("joint", "vocabulary"), []),
    ],
)
def test_rejects_what_the_code_does_not_implement(path, value):
    config = _config_with_vocabulary()
    *parents, key = path
    node = config
    for name in parents:
        node = node[name]
    node[key] = value
    with pytest.raises(UnsupportedModel, match=key):
        check_config(config)


def test_missing_weights_are_reported_as_unsupported():
    from talktome_server.parakeet import Parakeet

    with pytest.raises(UnsupportedModel, match="lack"):
        Parakeet(_config_with_vocabulary(), {})


def test_an_extra_encoder_layer_is_reported():
    import mlx.core as mx

    from talktome_server.parakeet import Parakeet

    config = _config_with_vocabulary()
    lstm = "decoder.prediction.dec_rnn.lstm"
    weights = {
        "joint.joint_net.2.weight": mx.zeros((2 + 1 + 5, 1)),
        "decoder.prediction.embed.weight": mx.zeros((2 + 1, 1)),
        **{f"encoder.layers.{i}.norm_out.weight": mx.zeros(1) for i in range(25)},  # config says 24
        **{f"{lstm}.{i}.Wx": mx.zeros(1) for i in range(2)},
    }
    with pytest.raises(UnsupportedModel, match="encoder.layers.24"):
        Parakeet(config, weights)
