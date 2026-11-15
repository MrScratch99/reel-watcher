#!/usr/bin/env python3
"""Assemble captures/<slug>/manifest.json from named args (safe JSON escaping).

Keeping JSON construction in python avoids fragile shell quoting of titles and
descriptions. Cookie data is never an input here — it must never reach the manifest.

Usage: write_manifest.py --out PATH --slug S --source SRC --type T --status STATUS
       [--errors a,b,c] [--title ...] [--channel ...] [--duration N]
       [--upload-date YYYYMMDD] [--t-source S] [--t-language L] [--t-words N]
       [--frame-count N] [--frame-interval N]
"""
import argparse
import json
import sys


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--out", required=True)
    p.add_argument("--slug", default="")
    p.add_argument("--source", default="")
    p.add_argument("--type", default="")
    p.add_argument("--status", default="failed")
    p.add_argument("--errors", default="")
    p.add_argument("--title", default="")
    p.add_argument("--channel", default="")
    p.add_argument("--duration", default="0")
    p.add_argument("--upload-date", default="")
    p.add_argument("--t-source", default="none")
    p.add_argument("--t-language", default="")
    p.add_argument("--t-words", default="0")
    p.add_argument("--frame-count", default="0")
    p.add_argument("--frame-interval", default="0")
    a = p.parse_args()

    def as_int(v):
        try:
            return int(float(v))
        except (TypeError, ValueError):
            return 0

    errors = [e for e in a.errors.split(",") if e.strip()]
    manifest = {
        "slug": a.slug,
        "source": a.source,
        "type": a.type,
        "status": a.status,
        "errors": errors,
        "title": a.title,
        "channel": a.channel,
        "duration_s": as_int(a.duration),
        "upload_date": a.upload_date,
        "transcript": {
            "path": "transcript.txt",
            "source": a.t_source,
            "language": a.t_language,
            "word_count": as_int(a.t_words),
        },
        "frames": {
            "dir": "frames/",
            "count": as_int(a.frame_count),
            "interval_s": as_int(a.frame_interval),
        },
    }
    with open(a.out, "w", encoding="utf-8") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=2)
        f.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
