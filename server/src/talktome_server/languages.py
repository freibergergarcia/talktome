"""Turn "the speaker uses these languages" into "these tokens may appear".

Parakeet v3 has no language input: it guesses from the audio, and on short or
unclear clips it sometimes guesses a language the speaker never uses (English
heard as Russian, written in Cyrillic). Its vocabulary mixes Latin, Cyrillic
and Greek tokens, so knowing the speaker's languages rules out whole alphabets.
It cannot tell English from Portuguese: those share an alphabet.
"""

import unicodedata

import numpy as np

# The 25 languages of parakeet-tdt-0.6b-v3 and the alphabet each is written in.
ALPHABETS = {
    **dict.fromkeys(["bg", "ru", "uk"], "CYRILLIC"),
    "el": "GREEK",
    **dict.fromkeys(
        ["cs", "da", "de", "en", "es", "et", "fi", "fr", "hr", "hu", "it", "lt", "lv"]
        + ["mt", "nl", "pl", "pt", "ro", "sk", "sl", "sv"],
        "LATIN",
    ),
}


def parse_languages(value: str | None) -> frozenset[str] | None:
    """The OpenAI `language` field holds one ISO-639-1 code; a comma-separated
    list is accepted too. Region subtags are dropped (pt-BR -> pt)."""
    codes = {part.strip().split("-")[0].lower() for part in (value or "").split(",")}
    codes.discard("")
    return frozenset(codes) or None


def token_mask(vocabulary: list[str], languages: frozenset[str] | None) -> np.ndarray | None:
    """True for tokens whose letters all belong to the languages' alphabets.
    Digits, punctuation and the word marker belong to every language. None
    means no restriction: no languages given, or one the model does not know."""
    if not languages or not languages <= ALPHABETS.keys():
        return None
    alphabets = {ALPHABETS[code] for code in languages}
    return np.array([all(_alphabet(ch) in alphabets for ch in token if ch.isalpha()) for token in vocabulary])


def _alphabet(letter: str) -> str:
    return unicodedata.name(letter, "UNKNOWN").split()[0]
