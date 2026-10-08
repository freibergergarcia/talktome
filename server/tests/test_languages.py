import pytest

from talktome_server.languages import choose_languages, parse_languages, token_mask

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


def test_unknown_codes_are_ignored():
    # The model cannot write Japanese anyway; English still rules out the rest.
    assert token_mask(VOCAB, frozenset({"en", "ja"})).tolist() == token_mask(VOCAB, frozenset({"en"})).tolist()


@pytest.mark.parametrize("languages", [None, frozenset({"ja"})])
def test_no_mask_without_a_known_language(languages):
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


@pytest.mark.parametrize(
    "requested,default,expected",
    [
        (frozenset({"pt"}), frozenset({"en"}), {"pt"}),  # a request names its own languages
        (None, frozenset({"en"}), {"en"}),  # or relies on the server's
        (frozenset({"zz"}), frozenset({"en"}), {"en"}),  # unknown codes cannot lift the server's guard
        (frozenset({"zz"}), None, None),
    ],
)
def test_choose_languages(requested, default, expected):
    assert choose_languages(requested, default) == (frozenset(expected) if expected else None)
