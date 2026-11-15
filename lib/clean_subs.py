#!/usr/bin/env python3
"""Convert a VTT or SRT subtitle file into clean, de-overlapped plain text.

This is the FALLBACK transcript path (non-YouTube captioned sources). YouTube
auto-captions are "rolling": each cue repeats the tail of the previous cue plus
a word or two, so naive line dedup leaves a wall of overlapping fragments. We
merge cues by the longest word-level suffix/prefix overlap instead.

Usage:
    clean_subs.py <subtitle-file> <out-text-path>

Prints a JSON line: {"ok": true, "word_count": N} or {"ok": false, "error": ...}.
"""
import html
import json
import re
import sys

TIMING = re.compile(r"-->")
CUE_SETTING = re.compile(r"^\s*(align|position|size|line|region):", re.IGNORECASE)
INDEX_LINE = re.compile(r"^\s*\d+\s*$")
TAG = re.compile(r"<[^>]+>")
# Block-level metadata: skip the WHOLE block when its first line is one of these,
# so multi-line NOTE/STYLE/header blocks don't leak continuation lines into text.
BLOCK_SKIP_PREFIXES = ("WEBVTT", "NOTE", "STYLE")
MAX_OVERLAP_WORDS = 60  # cap the suffix/prefix search so long files stay fast


def cue_texts(raw: str):
    """Yield the text of each cue, stripped of markup, in order."""
    for block in re.split(r"\n\s*\n", raw):
        stripped = [ln.strip() for ln in block.splitlines() if ln.strip()]
        if not stripped:
            continue
        if any(stripped[0].startswith(p) for p in BLOCK_SKIP_PREFIXES):
            continue  # metadata block — skip it entirely
        text_lines = []
        for s in stripped:
            if TIMING.search(s) or CUE_SETTING.match(s) or INDEX_LINE.match(s):
                continue
            s = html.unescape(TAG.sub("", s))
            s = re.sub(r"\s+", " ", s).strip()
            if s:
                text_lines.append(s)
        if text_lines:
            yield " ".join(text_lines)


def merge_overlap(cues):
    """Merge a sequence of cue strings by longest word-level suffix/prefix overlap."""
    acc: list[str] = []
    for cue in cues:
        words = cue.split()
        if not words:
            continue
        max_k = min(len(acc), len(words), MAX_OVERLAP_WORDS)
        k = 0
        for cand in range(max_k, 0, -1):
            if acc[-cand:] == words[:cand]:
                k = cand
                break
        acc.extend(words[k:])
    return " ".join(acc)


def main() -> int:
    if len(sys.argv) != 3:
        print(json.dumps({"ok": False, "error": "usage: clean_subs.py <sub> <out>"}))
        return 2
    sub_path, out_path = sys.argv[1], sys.argv[2]
    try:
        with open(sub_path, "r", encoding="utf-8", errors="replace") as f:
            raw = f.read()
    except OSError as e:
        print(json.dumps({"ok": False, "error": str(e)}))
        return 1

    text = merge_overlap(list(cue_texts(raw))).strip()
    if not text:
        print(json.dumps({"ok": False, "error": "no cue text found"}))
        return 1
    with open(out_path, "w", encoding="utf-8") as f:
        f.write(text + "\n")
    print(json.dumps({"ok": True, "word_count": len(text.split())}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
