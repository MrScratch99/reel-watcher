#!/usr/bin/env python3
"""Fetch a clean YouTube transcript via youtube-transcript-api.

The library returns already-segmented caption cues with no rolling-overlap
artifact, so this is the preferred path for YouTube (no audio download, instant).

Usage:
    yt_transcript.py <youtube-url-or-id> <out-text-path>

On success: writes plain text to <out-text-path> and prints a JSON line to
stdout: {"ok": true, "language": "en", "word_count": 123}
On failure: prints {"ok": false, "error": "..."} and exits non-zero.
The orchestrator treats any non-zero exit as "no youtube-api transcript, fall
back" — it never aborts the whole capture.
"""
from __future__ import annotations  # `str | None` annotations safe on 3.9

import json
import re
import sys
from contextlib import redirect_stdout


def video_id(s: str) -> str | None:
    """Extract an 11-char video id from a URL or accept a bare id."""
    if re.fullmatch(r"[A-Za-z0-9_-]{11}", s):
        return s
    patterns = [
        r"youtu\.be/([A-Za-z0-9_-]{11})",
        r"[?&]v=([A-Za-z0-9_-]{11})",
        r"/shorts/([A-Za-z0-9_-]{11})",
        r"/embed/([A-Za-z0-9_-]{11})",
        r"/live/([A-Za-z0-9_-]{11})",
    ]
    for p in patterns:
        m = re.search(p, s)
        if m:
            return m.group(1)
    return None


def fetch_segments(vid: str, languages):
    """Return (segments, language_code). Supports youtube-transcript-api 1.x
    (instance API) and 0.6.x (classmethods). Library stdout is redirected to
    stderr so it can never corrupt our JSON line on stdout."""
    from youtube_transcript_api import YouTubeTranscriptApi

    with redirect_stdout(sys.stderr):
        # 1.x instance API
        api = YouTubeTranscriptApi()
        if hasattr(api, "fetch"):
            fetched = api.fetch(vid, languages=languages)
            lang = getattr(fetched, "language_code", "unknown")
            return [{"text": s.text} for s in fetched], lang

        # 0.6.x classmethod API
        tl = YouTubeTranscriptApi.list_transcripts(vid)
        try:
            tr = tl.find_manually_created_transcript(languages)
        except Exception:
            tr = tl.find_generated_transcript(languages)
        data = tr.fetch()
        return [{"text": d["text"]} for d in data], getattr(tr, "language_code", "unknown")


def main() -> int:
    if len(sys.argv) != 3:
        print(json.dumps({"ok": False, "error": "usage: yt_transcript.py <url|id> <out>"}))
        return 2
    src, out_path = sys.argv[1], sys.argv[2]
    vid = video_id(src)
    if not vid:
        print(json.dumps({"ok": False, "error": "not a youtube url/id"}))
        return 3
    try:
        segs, lang = fetch_segments(vid, ["en", "sv", "en-US", "en-GB"])
    except Exception as e:  # noqa: BLE001 - report any failure, let caller fall back
        print(json.dumps({"ok": False, "error": f"{type(e).__name__}: {e}"}))
        return 1

    text = " ".join(s["text"].replace("\n", " ").strip() for s in segs if s["text"].strip())
    text = re.sub(r"\s+", " ", text).strip()
    if not text:
        print(json.dumps({"ok": False, "error": "empty transcript"}))
        return 1
    with open(out_path, "w", encoding="utf-8") as f:
        f.write(text + "\n")
    print(json.dumps({"ok": True, "language": lang, "word_count": len(text.split())}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
