import pytest

from talktome_server.languages import parse_languages, token_mask

VOCAB = ["<unk>", "▁the", "▁при", "ção", "1", ",", "▁Ωμ", "▁"]


def test_latin_languages_drop_cyrillic_and_greek():
    keep = token_mask(VOCAB, frozenset({"en", "pt"}))
    assert keep.tolist() == [True, True, False, True, True, True, False, True]


def test_cyrillic_language_keeps_only_cyrillic_words():
    keep = token_mask(VOCAB, frozenset({"ru"}))
    assert keep.tolist() == [False, False, True, False, True, True, False, True]


def test_mixed_scripts_keep_both():
    keep = token_mask(VOCAB, frozenset({"en", "el"}))
    assert keep.tolist() == [True, True, False, True, True, True, True, True]


@pytest.mark.parametrize("languages", [None, frozenset({"en", "ja"})])
def test_no_mask_when_unrestricted_or_unknown(languages):
    # A language the model does not know gives no basis for a filter.
    assert token_mask(VOCAB, languages) is None


@pytest.mark.parametrize(
    "value,expected",
    [
        ("en", {"en"}),
        ("en, PT ,", {"en", "pt"}),
        ("pt-BR", {"pt"}),
        ("", None),
        (None, None),
    ],
)
def test_parse_languages(value, expected):
    assert parse_languages(value) == (frozenset(expected) if expected else None)
