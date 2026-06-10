#!/usr/bin/env python3
"""
One-shot fix for transcripts produced by the pre-detokenizer-fix Caddie build.

The bug: SentencePiece sub-word tokens were joined with spaces, fragmenting words:
    "play"      → "pla y"
    "customers" → "c ust om ers"
    "platform"  → "plat form"
    "there's"   → "there ' s"

This script walks each affected transcript stored in the Caddie SQLite database
and re-merges adjacent fragments using a dictionary lookup, then rewrites the
JSON in place. No audio re-processing — we don't have the framework outside
the app — so this is heuristic: a fragment whose merge isn't in the dictionary
stays fragmented (rare proper nouns may not fully recover).

USAGE
    python3 scripts/fix-broken-transcripts.py
    python3 scripts/fix-broken-transcripts.py --dry-run     # preview
    python3 scripts/fix-broken-transcripts.py --all         # also touch clean ones
    python3 scripts/fix-broken-transcripts.py --db /path/to/caddie.db
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sqlite3
import sys
from pathlib import Path


DEFAULT_DB = Path.home() / "Library" / "Application Support" / "Caddie" / "caddie.db"
DICT_PATH = "/usr/share/dict/words"
MAX_MERGE_LEN = 6

# /usr/share/dict/words contains many obscure 2-3 letter "words" (fut, ure,
# inde, fo, pat, tod, aga, ott...) that pollute merge decisions: the DP would
# happily keep "fut" + "ure" as two valid singletons instead of merging into
# "future". For short tokens we only trust this curated whitelist of words
# that genuinely occur in English meeting transcripts.
COMMON_SHORT = {
    # 1-letter
    "a", "i",
    # 2-letter
    "am", "an", "as", "at", "be", "by", "do", "go", "he", "hi", "if",
    "in", "is", "it", "me", "my", "no", "of", "oh", "ok", "on", "or",
    "so", "to", "up", "us", "we",
    # 3-letter
    "all", "and", "any", "are", "ask", "bad", "big", "bit", "but", "buy",
    "can", "cut", "did", "end", "few", "for", "get", "got", "had", "has",
    "her", "him", "his", "how", "its", "key", "led", "let", "low", "man",
    "may", "new", "non", "not", "now", "off", "old", "one", "our", "out",
    "own", "put", "ran", "run", "saw", "say", "see", "set", "she", "sir",
    "ten", "the", "too", "top", "try", "two", "use", "war", "was", "way",
    "who", "why", "yes", "yet", "you",
    # interjections/fillers common in spoken transcripts
    "um", "uh", "hm",
}

# Words that should not concatenate with their neighbors even when /usr/share/dict
# happens to contain the result (it does, for archaic terms like "tobe", "doit",
# "godown", "atone", "orthis", "ofthe"). When ALL constituent tokens of a multi-
# token merge are in this set, suppress the merge — keep them separate as the
# original ASR boundaries intended.
NEVER_MERGE = {
    # 1-3 letter function words (everything in COMMON_SHORT plus a few)
    "a", "i",
    "am", "an", "as", "at", "be", "by", "do", "go", "he", "hi", "if",
    "in", "is", "it", "me", "my", "no", "of", "oh", "ok", "on", "or",
    "so", "to", "up", "us", "we",
    "all", "and", "any", "are", "but", "can", "did", "for", "get", "got",
    "had", "has", "her", "him", "his", "how", "its", "let", "may", "new",
    "non", "not", "now", "off", "old", "one", "our", "out", "own", "put",
    "ran", "run", "saw", "say", "see", "set", "she", "sir", "the", "too",
    "top", "try", "two", "use", "was", "way", "who", "why", "yes", "yet",
    "you",
    # 4+ letter common standalone words that almost never form compounds
    # with their neighbors in spoken transcripts
    "that", "this", "have", "with", "they", "them", "from", "want",
    "over", "down", "back", "very", "well", "just", "what", "when",
    "make", "more", "some", "than", "like", "time", "year", "good",
    "much", "even", "also", "only", "both", "each", "ever", "your",
    "will", "been", "were", "said", "says", "still", "then", "into",
    "onto", "does", "going",
}

# Real compound words formed from neighbors that ARE individually function words
# (no+thing, some+thing, every+body…). Bypasses the NEVER_MERGE block when the
# merged result is one of these.
COMPOUND_WHITELIST = {
    "nothing", "something", "anything", "everything",
    "nobody", "somebody", "anybody", "everybody",
    "nowhere", "somewhere", "anywhere", "everywhere",
    "however", "whatever", "whenever", "wherever",
    "myself", "yourself", "himself", "herself", "itself", "ourselves",
    "themselves", "yourselves", "oneself",
    "into", "onto", "upon", "within", "without",
    "another", "anyway", "anyhow", "instead", "indeed", "perhaps",
    "today", "tonight", "tomorrow", "yesterday", "alongside",
    "throughout", "everyday", "altogether", "whereas",
}

# Contractions and acronyms that /usr/share/dict/words misses.
EXTRA_WORDS = {
    "ok", "okay", "yeah", "yep", "nope", "hmm",
    "i'm", "i'll", "i've", "i'd",
    "you're", "you've", "you'll", "you'd",
    "we're", "we've", "we'll", "we'd",
    "they're", "they've", "they'll", "they'd",
    "it's", "that's", "there's", "here's", "what's", "who's", "where's",
    "he's", "she's", "let's", "how's",
    "don't", "didn't", "doesn't", "won't", "wouldn't", "couldn't",
    "shouldn't", "isn't", "aren't", "wasn't", "weren't", "haven't",
    "hasn't", "hadn't", "can't", "cannot", "mustn't",
}


def load_dictionary() -> set[str]:
    if not os.path.exists(DICT_PATH):
        sys.exit(f"Dictionary not found at {DICT_PATH}")
    with open(DICT_PATH, encoding="utf-8") as f:
        words = {line.strip().lower() for line in f if line.strip()}
    return words | EXTRA_WORDS


def looks_broken(text: str) -> bool:
    """Real prose has very few standalone single-letter words. The pre-fix
    output is full of them ('y', 'c', 'h'…). >5% single-letter tokens in a
    transcript longer than ~20 words is the unmistakable signature."""
    words = text.split()
    if len(words) < 20:
        return False
    single = sum(1 for w in words if len(w) == 1 and w.isalpha())
    return single / len(words) > 0.05


def normalize_apostrophes(text: str) -> str:
    """Collapse curly apostrophes to ASCII so dictionary lookups match."""
    return text.replace("’", "'").replace("‘", "'")


def _is_valid_word(stripped: str, dictionary: set[str]) -> bool:
    """A token counts as a valid word if it's in the system dictionary AND
    either (a) at least 4 characters or (b) one of the common short words.
    The system dictionary stores only base forms (no plurals, past tense,
    gerunds), so we also check the most common English suffix-stripped forms.
    Without that, "customers" / "playing" / "decisions" never validate and
    the DP either over-merges or leaves obvious words fragmented."""
    if not stripped:
        return False
    lower = stripped.lower()

    if len(stripped) <= 3:
        return lower in COMMON_SHORT or lower in EXTRA_WORDS

    if lower in dictionary or lower in EXTRA_WORDS:
        return True

    # Inflection fallbacks. Order matters: -ies before -es before -s,
    # -ing before -ed.
    if lower.endswith("ies") and len(lower) >= 5 and (lower[:-3] + "y") in dictionary:
        return True
    if lower.endswith("ing") and len(lower) >= 6 and (
        lower[:-3] in dictionary or (lower[:-3] + "e") in dictionary
    ):
        return True
    if lower.endswith("ed") and len(lower) >= 5 and (
        lower[:-2] in dictionary or lower[:-1] in dictionary
    ):
        return True
    if lower.endswith("es") and len(lower) >= 5 and (
        lower[:-2] in dictionary or lower[:-1] in dictionary
    ):
        return True
    if lower.endswith("s") and len(lower) >= 4 and lower[:-1] in dictionary:
        return True
    if lower.endswith("ly") and len(lower) >= 5 and lower[:-2] in dictionary:
        return True
    if lower.endswith("er") and len(lower) >= 5 and (
        lower[:-2] in dictionary or lower[:-1] in dictionary
    ):
        return True
    return False


def merge_fragments(text: str, dictionary: set[str]) -> str:
    """Find the segmentation of the token sequence that maximizes the number of
    valid dictionary words (then total characters covered). Tie-breaker: prefer
    earlier splits — i.e., preserve original token boundaries when a single
    token is already a valid word, instead of greedily merging it into a longer
    accidentally-valid word like "We" + "st" → "West".

    Solved with DP: dp[i] = best segmentation of tokens[0:i].
    """
    tokens = text.split()
    if not tokens:
        return text
    n = len(tokens)

    # Score per segmentation = (total_chars_in_valid_groups, total_merges, total_groups).
    # 1. Cover as much real text as possible (chars first).
    # 2. On char ties, prefer the segmentation with more merged-into-real-words
    #    groups — this keeps "platform" (1 merge) over "plat + form" (0 merges
    #    of two archaic dict entries).
    # 3. On further ties, prefer more groups — that keeps "or this" (2 groups)
    #    over "orthis" (1 group, also in the dict but obviously wrong).
    NEG = (-1, -1, -1)
    dp_score: list[tuple[int, int, int]] = [NEG] * (n + 1)
    dp_back: list[int] = [-1] * (n + 1)
    dp_score[0] = (0, 0, 0)

    for i in range(1, n + 1):
        # Iterate j from smallest to largest so that on score ties, the smallest
        # j wins (strict > below). That preserves segmentations that split early
        # (the original boundary between, e.g., "We" and "st").
        for j in range(max(0, i - MAX_MERGE_LEN), i):
            if dp_score[j] == NEG:
                continue
            concat = "".join(tokens[j:i])
            stripped = concat.rstrip(".,;:!?")
            valid = _is_valid_word(stripped, dictionary)

            # Block multi-token merges where every constituent is a function word
            # (to + be, go + down, do + it, over + time…) — those should stay
            # separate. Real compounds (no + thing → nothing) bypass via the
            # COMPOUND_WHITELIST.
            if valid and (i - j) > 1:
                constituents = [t.rstrip(".,;:!?").lower() for t in tokens[j:i]]
                constituents = [c for c in constituents if c]
                all_function = constituents and all(c in NEVER_MERGE for c in constituents)
                if all_function and stripped.lower() not in COMPOUND_WHITELIST:
                    valid = False

            if valid:
                multi = (i - j) > 1
                # Compound whitelist hits (nothing/everybody/within…) get a merge
                # bonus so they beat the alternative split, which would otherwise
                # win on the "more groups" tie-breaker.
                if multi and stripped.lower() in COMPOUND_WHITELIST:
                    merges = 2
                elif multi:
                    merges = 1
                else:
                    merges = 0
                add = (len(stripped), merges, 1)
            else:
                add = (0, 0, 1)
            cand = (
                dp_score[j][0] + add[0],
                dp_score[j][1] + add[1],
                dp_score[j][2] + add[2],
            )
            if cand > dp_score[i]:
                dp_score[i] = cand
                dp_back[i] = j

    # Reconstruct groups by walking dp_back from n back to 0.
    groups: list[str] = []
    pos = n
    while pos > 0:
        j = dp_back[pos]
        if j < 0:
            # Shouldn't happen since j=i-1 always produces a valid path; fall back.
            groups.append(tokens[pos - 1])
            pos -= 1
        else:
            groups.append("".join(tokens[j:pos]))
            pos = j
    groups.reverse()

    return _reflow_punctuation(" ".join(groups))


def _reflow_punctuation(text: str) -> str:
    """Remove stray spaces around punctuation produced when the fragment ' . '
    survives a non-merge: 'company .' → 'company.', 'word ' s' → 'word's'."""
    text = re.sub(r"\s+([.,;:!?])", r"\1", text)
    text = re.sub(r"(\w)\s+'\s*(\w)", r"\1'\2", text)
    text = re.sub(r"(\w)\s+'\s+", r"\1' ", text)
    text = re.sub(r"\s{2,}", " ", text)
    return text.strip()


def fix_transcript(transcript: dict, dictionary: set[str]) -> dict:
    """Apply merge_fragments to each segment and rebuild fullText. The fullText
    format mirrors TranscriptMerger.generateFullText in the Swift code: a
    `[SPEAKER_NN]` header introduced when the speaker changes (blank line
    between speaker changes), then segment texts space-separated within a run."""
    segments = transcript.get("segments", [])
    for segment in segments:
        original = normalize_apostrophes(segment.get("text", ""))
        segment["text"] = merge_fragments(original, dictionary)

    transcript["segments"] = segments
    transcript["fullText"] = _build_full_text(segments)
    return transcript


def _build_full_text(segments: list[dict]) -> str:
    """Mirror of Swift's generateFullText(segments:) — speaker headers + spacing."""
    if not segments:
        return ""
    parts: list[str] = []
    current_speaker: str | None = None
    for segment in segments:
        speaker = segment.get("speaker", "Speaker")
        text = segment.get("text", "")
        if speaker != current_speaker:
            if current_speaker is not None:
                parts.append("\n\n")
            parts.append(f"[{speaker}]\n")
            current_speaker = speaker
        else:
            parts.append(" ")
        parts.append(text)
    return "".join(parts)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--db", default=str(DEFAULT_DB), help="path to caddie.db")
    parser.add_argument("--dry-run", action="store_true", help="preview without writing")
    parser.add_argument("--all", action="store_true", help="process every done meeting, not just broken ones")
    args = parser.parse_args()

    if not os.path.exists(args.db):
        sys.exit(f"Database not found: {args.db}")

    print(f"Loading dictionary from {DICT_PATH}...")
    dictionary = load_dictionary()
    print(f"Loaded {len(dictionary):,} words.\n")

    conn = sqlite3.connect(args.db)
    conn.row_factory = sqlite3.Row
    cur = conn.cursor()

    cur.execute(
        "SELECT meeting_id, title, transcript FROM meetings "
        "WHERE status = 'done' AND transcript IS NOT NULL "
        "ORDER BY created_at DESC"
    )
    rows = cur.fetchall()

    if not rows:
        print("No completed meetings with transcripts. Nothing to do.")
        return

    fixed = 0
    skipped = 0
    for row in rows:
        meeting_id = row["meeting_id"]
        title = row["title"]
        try:
            transcript = json.loads(row["transcript"])
        except json.JSONDecodeError as e:
            print(f"  [skip] {meeting_id} '{title}': malformed JSON ({e})")
            continue

        full_text = transcript.get("fullText", "")
        broken = looks_broken(full_text)

        if not broken and not args.all:
            print(f"  [skip] {meeting_id} '{title}': looks fine")
            skipped += 1
            continue

        original_preview = full_text.split("\n")[0][:100] if full_text else ""
        new_transcript = fix_transcript(transcript, dictionary)
        new_preview = new_transcript["fullText"].split("\n")[0][:100]

        action = "[dry]" if args.dry_run else "[fix]"
        print(f"  {action} {meeting_id} '{title}'")
        print(f"        before: {original_preview!r}")
        print(f"        after : {new_preview!r}")

        if not args.dry_run:
            cur.execute(
                "UPDATE meetings SET transcript = ? WHERE meeting_id = ?",
                (json.dumps(new_transcript, sort_keys=True), meeting_id),
            )
        fixed += 1

    if not args.dry_run:
        conn.commit()
    conn.close()

    print()
    print(f"Done. {fixed} fixed, {skipped} skipped.")
    if args.dry_run:
        print("(--dry-run was set; no changes written.)")


if __name__ == "__main__":
    main()
