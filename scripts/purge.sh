#!/bin/bash
# Delete a capture's heavy media (video, audio, frames) and keep the text:
# manifest.json, transcript.txt, meta.txt.
#
#   bash scripts/purge.sh <slug>      (the slug from the capture's manifest.json)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ "$#" -eq 1 ] || { echo "Usage: bash scripts/purge.sh <slug>" >&2; exit 2; }
case "$1" in ''|*/*|.*|*..*) echo "Bad slug: $1" >&2; exit 2 ;; esac
DIR="$ROOT/captures/$1"
[ -f "$DIR/manifest.json" ] || { echo "No capture named $1" >&2; exit 1; }
rm -f -- "$DIR"/video.* "$DIR/audio.wav" "$DIR"/sub.*
rm -rf -- "$DIR/frames"
echo "Purged media for $1"
