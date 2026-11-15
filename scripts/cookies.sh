#!/bin/bash
# Save the Instagram (and TikTok/Facebook) login from a browser, once, so
# watch.sh can open reels that need a login. Only those sites' cookies are
# kept; the rest of the browser's cookies are thrown away.
#
#   bash scripts/cookies.sh <chrome|safari|firefox|edge|brave|arc> <any reel url>
#
# macOS may ask once to let it read the browser's saved logins ("Safe Storage"):
# choose Allow. Writes ~/.config/reel-watcher/cookies.txt (only you can read it).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="$ROOT/tools/bin:$ROOT/.venv/bin:$PATH"
[ "$#" -eq 2 ] || { echo "Usage: bash scripts/cookies.sh <browser> <reel url>" >&2; exit 2; }
case "$1" in chrome|safari|firefox|edge|brave|arc|chromium|opera|vivaldi) ;; *)
  echo "Unknown browser: $1" >&2; exit 2 ;; esac
command -v yt-dlp >/dev/null 2>&1 || { echo "Not installed yet: run /setup first." >&2; exit 1; }

DEST_DIR="$HOME/.config/reel-watcher"
DEST="$DEST_DIR/cookies.txt"
mkdir -p "$DEST_DIR"; chmod 700 "$DEST_DIR"
umask 077
TMP="$(mktemp "$DEST_DIR/.all.XXXXXX")"
trap 'rm -f "$TMP"' EXIT

yt-dlp --no-warnings --cookies-from-browser "$1" --cookies "$TMP" \
  --skip-download --no-playlist --print "%(id)s" -- "$2" >/dev/null 2>&1 || true

# Keep the "# " header lines and the cookies of the social sites only. A cookie
# line has 7 tab-separated fields; HttpOnly ones start with "#HttpOnly_", so
# they are matched on the domain, never kept just for starting with "#".
awk -F'\t' '
  NF >= 7 { d = $1; sub(/^#HttpOnly_/, "", d); if (d ~ /(^|\.)(instagram|tiktok|facebook)\.com$/) print; next }
  /^# / { print }' "$TMP" > "$DEST.new"
KEPT="$(awk -F'\t' 'NF >= 7' "$DEST.new" | wc -l | tr -d ' ')"
if [ "$KEPT" -eq 0 ]; then
  rm -f "$DEST.new"
  echo "No Instagram/TikTok/Facebook login found in $1. Log in there first, then run this again." >&2
  exit 1
fi
mv -f "$DEST.new" "$DEST"; chmod 600 "$DEST"
echo "Saved: $KEPT cookies for the social sites in $DEST"
