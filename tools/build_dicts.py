#!/usr/bin/env python3
"""Build Comp dictionaries from raw frequency lists and compute
chord-disambiguation statistics used in the design paper.

Inputs : dictionaries/{lang}_raw.txt   ("word count" per line, freq-descending)
Outputs: dictionaries/{lang}.tsv       (top APP_N cleaned words, word\tcount)
         webapp/dict/{lang}.json       (top WEB_N as [[word, count], ...])
         docs/stats_{lang}.json        (disambiguation metrics for the paper)
"""
import json
import re
import sys
import unicodedata
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LANGS = ["en", "es", "fr", "de", "it", "pt"]
APP_N = 25000
WEB_N = 8000
ANALYSIS_N = 10000

WORD_RE = re.compile(r"^[a-zà-öø-ÿœßäöüáéíóúâêîôûàèìòùãõçñ'’-]+$", re.IGNORECASE)

# The subtitle corpus tokenizes contractions apart ("doesn't" -> "doesn" + "'t").
# Fragments with a unique stem are rebuilt with their exact corpus count;
# stems that double as real words (can, it, i, ...) get contractions with
# counts distributed from the observed suffix-token masses
# ('s 14.3M, 't 9.6M, 'm 4.4M, 're 4.1M, 'll 2.9M in the 2018 en list).
FRAGMENT_TO_CONTRACTION = {
    "en": {"doesn": "doesn't", "couldn": "couldn't", "wouldn": "wouldn't",
           "shouldn": "shouldn't", "didn": "didn't", "isn": "isn't",
           "wasn": "wasn't", "weren": "weren't", "hasn": "hasn't",
           "hadn": "hadn't", "aren": "aren't", "mustn": "mustn't",
           "needn": "needn't", "ain": "ain't", "don": "don't"},
}

EXTRA_WORDS = {
    "en": [("i'm", 4386000), ("it's", 4500000), ("that's", 3500000),
           ("can't", 2000000), ("you're", 2200000), ("i'll", 1500000),
           ("what's", 1300000), ("i've", 1200000), ("he's", 1100000),
           ("we're", 1000000), ("she's", 900000), ("there's", 900000),
           ("they're", 850000), ("won't", 830000), ("i'd", 800000),
           ("let's", 700000), ("you'll", 600000), ("haven't", 560000),
           ("we'll", 500000), ("you've", 500000), ("we've", 350000),
           ("who's", 300000), ("you'd", 300000), ("here's", 250000),
           ("they've", 200000), ("he'll", 160000), ("she'll", 120000),
           ("it'll", 110000), ("he'd", 100000), ("they'll", 100000),
           ("she'd", 90000), ("we'd", 80000), ("they'd", 70000)],
}

# orphan suffix tokens and true junk to drop entirely
DROP = {
    "en": {"ll", "ve", "re", "em", "won"},  # "won" re-added via EXTRA below
}
DROP["en"].discard("won")  # keep "won" (past of win); "won't" comes from EXTRA


def clean(lang: str):
    raw = ROOT / "dictionaries" / f"{lang}_raw.txt"
    frag_map = FRAGMENT_TO_CONTRACTION.get(lang, {})
    drop = DROP.get(lang, set())
    words, seen = [], set()
    for line in raw.read_text(encoding="utf-8").splitlines():
        parts = line.strip().split()
        if len(parts) != 2:
            continue
        w, c = parts[0].lower(), int(parts[1])
        # keep single letters only for real words (a, i, y ...)
        if len(w) == 1 and w not in ("a", "i", "y", "e", "o"):
            continue
        if not WORD_RE.match(w) or w.startswith(("-", "'")) or w.endswith("-"):
            continue
        if w in drop:
            continue
        w = frag_map.get(w, w)  # rebuild unique-stem contractions
        if w in seen:
            continue
        seen.add(w)
        words.append((w, c))
    for w, c in EXTRA_WORDS.get(lang, []):
        if w not in seen:
            seen.add(w)
            words.append((w, c))
    words.sort(key=lambda x: -x[1])
    return words


def strip_accents(w: str) -> str:
    folded = "".join(
        ch for ch in unicodedata.normalize("NFD", w) if unicodedata.category(ch) != "Mn"
    )
    return folded.replace("'", "").replace("’", "")


def is_subsequence(chord: str, word: str) -> bool:
    it = iter(word)
    return all(ch in it for ch in chord)


def analyze(lang: str, words):
    """For each of the top ANALYSIS_N words, find the minimal chord
    (first letter + following letters of the word, in order) at which the
    word becomes the single highest-frequency candidate among all words
    matching that chord.  Chord match rule: chord[0] == word[0] and chord
    is a subsequence of word (accents folded)."""
    top = words[:ANALYSIS_N]
    total_freq = sum(c for _, c in top)
    folded = [(strip_accents(w), w, c) for w, c in top]
    by_first = {}
    for fw, w, c in folded:
        by_first.setdefault(fw[0], []).append((fw, c))

    min_len_hist = {}
    weighted_keys = 0.0
    weighted_full = 0.0
    unresolved = 0
    for fw, w, c in folded:
        bucket = by_first.get(fw[0], [])
        found = None
        # chord = first k letters of the word (dedup keeps order semantics simple)
        for k in range(2, len(fw) + 1):
            chord = fw[:k]
            best = None
            tie = False
            for cw, cc in bucket:
                if len(cw) >= len(chord) and is_subsequence(chord, cw):
                    if best is None or cc > best[1]:
                        best, tie = (cw, cc), False
                    elif cc == best[1] and cw != best[0]:
                        tie = True
            if best and best[0] == fw and not tie:
                found = k
                break
        if len(fw) == 1:
            found = 1
        if found is None:
            found = len(fw)  # must type it fully (still ambiguous -> bar)
            unresolved += 1
        min_len_hist[found] = min_len_hist.get(found, 0) + 1
        weighted_keys += c * found
        weighted_full += c * len(fw)

    stats = {
        "lang": lang,
        "analysis_words": len(top),
        "unresolved_fraction": round(unresolved / len(top), 4),
        "min_chord_len_histogram": dict(sorted(min_len_hist.items())),
        "expected_keys_per_word_chord": round(weighted_keys / total_freq, 3),
        "expected_keys_per_word_full": round(weighted_full / total_freq, 3),
        "keystroke_savings_pct": round(100 * (1 - weighted_keys / weighted_full), 2),
    }
    return stats


def main():
    langs = sys.argv[1:] or LANGS
    for lang in langs:
        words = clean(lang)
        app = words[:APP_N]
        (ROOT / "dictionaries" / f"{lang}.tsv").write_text(
            "\n".join(f"{w}\t{c}" for w, c in app), encoding="utf-8"
        )
        web = words[:WEB_N]
        (ROOT / "webapp" / "dict" / f"{lang}.json").write_text(
            json.dumps(web, ensure_ascii=False, separators=(",", ":")),
            encoding="utf-8",
        )
        stats = analyze(lang, words)
        (ROOT / "docs" / f"stats_{lang}.json").write_text(
            json.dumps(stats, indent=2), encoding="utf-8"
        )
        print(f"{lang}: {len(words)} clean, savings {stats['keystroke_savings_pct']}% "
              f"({stats['expected_keys_per_word_chord']} vs {stats['expected_keys_per_word_full']} keys/word), "
              f"unresolved {stats['unresolved_fraction']*100:.1f}%")


if __name__ == "__main__":
    main()
