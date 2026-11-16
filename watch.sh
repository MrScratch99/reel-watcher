#!/usr/bin/env bash
#
# watch.sh — turn a video link (or local file) into something Claude can "watch":
#   transcript + sampled frames + metadata, written to one capture folder with a
#   machine-readable manifest.json.
#
# Usage:
#   ./watch.sh <url-or-path> [slug]
#
# Env:
#   WATCH_COOKIES_FILE     Netscape cookie file for auth-walled reels (Instagram).
#                          Default ~/.config/reel-watcher/cookies.txt, written by
#                          scripts/cookies.sh. Missing = public links only.
#   WATCH_WHISPER_MODEL    faster-whisper model name (default "base", fetched by /setup)
#
# Transcript resolution order:
#   1. YouTube  -> youtube-transcript-api (clean, instant, no download)
#   2. other captioned web -> yt-dlp subs -> clean_subs.py (rolling-overlap dedup)
#   3. reels / no-caption / local files -> on-device faster-whisper (language auto)
#
# Status (mirrored in exit code): ok=0, partial=10, failed=20.
#   ok      = transcript AND >=1 frame
#   partial = exactly one of them
#   failed  = neither / hard download failure / auth wall
#
# Nothing leaves the machine. Cookie data is never logged or written to the capture.

set -o pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$ROOT/lib"
CAP_ROOT="$ROOT/captures"
# Tools come from this folder (installed by /setup on a Mac: ffmpeg/ffprobe in
# tools/bin, yt-dlp and Python in .venv) or, in a Claude Code cloud session,
# from /opt/reel-watcher (installed by the environment's setup script,
# cloud/setup.sh; ffmpeg from apt).
if [ -x "$ROOT/.venv/bin/python" ]; then
  export PATH="$ROOT/tools/bin:$ROOT/.venv/bin:$PATH"
  PY="$ROOT/.venv/bin/python"; MODELS="$ROOT/tools/models"
elif [ -x /opt/reel-watcher/venv/bin/python ]; then
  export PATH="/opt/reel-watcher/venv/bin:$PATH"
  PY=/opt/reel-watcher/venv/bin/python; MODELS=/opt/reel-watcher/models
else
  PY=""; MODELS=""
fi
# A pre-exported cookie file (scripts/cookies.sh) means no Keychain prompt per run.
COOKIES_FILE="${WATCH_COOKIES_FILE:-$HOME/.config/reel-watcher/cookies.txt}"

FRAME_COUNT=10
WHISPER_CAP_S=3600        # 1 hour
# caption quality gate = 0.3 words/sec, applied as integer math (T_WORDS*10 >= DURATION*3)
EXIT_OK=0; EXIT_PARTIAL=10; EXIT_FAILED=20

ERRORS=()
record_error() { ERRORS+=("$1"); }
MEDIA_FAIL_NOTED=0
note_media_failed() {  # record media_download_failed at most once
  [ "$MEDIA_FAIL_NOTED" -eq 1 ] && return 0
  record_error "media_download_failed"; MEDIA_FAIL_NOTED=1
}
log() { echo ">> $*" >&2; }
die() { echo "ERROR: $*" >&2; exit 2; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing dependency: $1"; }

# --- args + dependencies ----------------------------------------------------
[ $# -ge 1 ] || die "usage: watch.sh <url-or-path> [slug]"
[ -n "$PY" ] || die "not installed yet: run /setup on a Mac, or add cloud/setup.sh to the cloud environment"
need yt-dlp; need ffmpeg; need ffprobe

SRC="$1"
RAW_SLUG="${2:-}"

sanitize_slug() {
  local s
  s="$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_')"
  while [ "$s" != "${s//../_}" ]; do s="${s//../_}"; done  # collapse all ".." sequences
  s="${s#.}"            # no leading dot (hidden dir)
  s="${s#_}"; s="${s%_}"
  printf '%s' "${s:0:80}"
}

if [ -n "$RAW_SLUG" ]; then
  SLUG="$(sanitize_slug "$RAW_SLUG")"
else
  SLUG="$(date +%Y%m%d-%H%M%S)"
fi
# Reject empty or punctuation-only slugs (e.g. "..." -> "."), which would
# collapse DIR onto the captures root. Require at least one alphanumeric.
case "$SLUG" in
  *[A-Za-z0-9]*) : ;;
  *) SLUG="$(date +%Y%m%d-%H%M%S)" ;;
esac

# --- input kind + type ------------------------------------------------------
INPUT_KIND="url"
if [ -e "$SRC" ]; then
  INPUT_KIND="local"
  [ -f "$SRC" ] || die "local path is not a regular file: $SRC"
  SRC_DIR="$(cd "$(dirname "$SRC")" 2>/dev/null && pwd)"
  [ -n "$SRC_DIR" ] || die "cannot resolve path: $SRC"
  SRC="$SRC_DIR/$(basename "$SRC")"
fi

detect_type() {
  if [ "$INPUT_KIND" = "local" ]; then echo "local"; return; fi
  case "$1" in
    *youtube.com*|*youtu.be*) echo "youtube" ;;
    *instagram.com*|*tiktok.com*) echo "reel" ;;
    *) echo "web" ;;
  esac
}
TYPE="$(detect_type "$SRC")"

# --- cookie args (never printed) -------------------------------------------
# Only attach cookies for hosts that actually need auth. YouTube returns HTTP 403
# on the video download when account cookies are attached, so it must stay
# cookie-free; Instagram/TikTok need them to get past the login wall.
needs_auth_cookies() {
  case "$1" in
    *instagram.com*|*tiktok.com*|*facebook.com*|*fb.watch*) return 0 ;;
    *) return 1 ;;
  esac
}
COOKIE_ARGS=()
if [ "$INPUT_KIND" = "url" ] && needs_auth_cookies "$SRC"; then
  if [ -n "$COOKIES_FILE" ] && [ -f "$COOKIES_FILE" ]; then
    COOKIE_ARGS=(--cookies "$COOKIES_FILE")          # file read — no Keychain prompt
  fi
fi

# --- capture dir (idempotent: clear stale frames) --------------------------
DIR="$CAP_ROOT/$SLUG"
mkdir -p "$DIR"
rm -rf "$DIR/frames"; mkdir -p "$DIR/frames"
TRANSCRIPT="$DIR/transcript.txt"
log "capture dir: $DIR  (type=$TYPE)"

# --- metadata ---------------------------------------------------------------
TITLE=""; CHANNEL=""; DURATION=0; UPLOAD_DATE=""
if [ "$INPUT_KIND" = "local" ]; then
  TITLE="$(basename "$SRC")"
  DURATION="$(ffprobe -v quiet -show_entries format=duration -of csv=p=0 "file:$SRC" 2>/dev/null | cut -d. -f1)"
else
  # Fetch metadata as one JSON object, then flatten each field to a single line
  # (a title with an embedded newline would otherwise shift the field reads).
  META="$(yt-dlp --no-warnings --skip-download --no-playlist "${COOKIE_ARGS[@]}" \
      --print "%(.{title,uploader,duration,upload_date})j" -- "$SRC" 2>/dev/null \
    | "$PY" -c '
import json, sys
try:
    d = json.loads(sys.stdin.read() or "{}")
except Exception:
    d = {}
flat = lambda x: " ".join(str(x if x is not None else "").split())
for key in ("title", "uploader", "duration", "upload_date"):
    print(flat(d.get(key)))
')"
  if [ -n "$META" ]; then
    { read -r TITLE; read -r CHANNEL; read -r DURATION; read -r UPLOAD_DATE; } <<<"$META"
  fi
fi
case "$DURATION" in ''|*[!0-9]*) DURATION=0 ;; esac
case "$UPLOAD_DATE" in NA|na) UPLOAD_DATE="" ;; esac

# --- media (download once; reused for whisper + frames) --------------------
VIDEO=""
ensure_media() {
  if [ -n "$VIDEO" ] && [ -f "$VIDEO" ]; then return 0; fi
  if [ "$INPUT_KIND" = "local" ]; then VIDEO="$SRC"; return 0; fi
  local existing
  existing="$(find "$DIR" -maxdepth 1 -name 'video.*' 2>/dev/null | head -1)"
  if [ -n "$existing" ]; then VIDEO="$existing"; return 0; fi
  log "downloading media (<=720p)..."
  # DL_GUARDS bound the download so one bad link can't fill the disk:
  # single video only, hard 2G size cap, reject livestreams (infinite).
  local DL_GUARDS=(--no-playlist --max-filesize 2G --match-filter "!is_live")
  yt-dlp --no-warnings "${DL_GUARDS[@]}" "${COOKIE_ARGS[@]}" \
    -f "bv*[height<=720]+ba/b[height<=720]/b" -o "$DIR/video.%(ext)s" -- "$SRC" >/dev/null 2>&1 \
    || yt-dlp --no-warnings "${DL_GUARDS[@]}" "${COOKIE_ARGS[@]}" -o "$DIR/video.%(ext)s" -- "$SRC" >/dev/null 2>&1
  VIDEO="$(find "$DIR" -maxdepth 1 -name 'video.*' 2>/dev/null | head -1)"
  [ -n "$VIDEO" ] && [ -f "$VIDEO" ]
}

# --- transcript -------------------------------------------------------------
T_SOURCE="none"; T_LANG=""; T_WORDS=0

# 1) YouTube -> youtube-transcript-api
if [ "$TYPE" = "youtube" ]; then
  log "trying youtube-transcript-api..."
  if YT_JSON="$("$PY" "$LIB/yt_transcript.py" "$SRC" "$TRANSCRIPT" 2>/dev/null)" && [ -s "$TRANSCRIPT" ]; then
    T_SOURCE="youtube-api"
    T_LANG="$(printf '%s' "$YT_JSON" | "$PY" -c 'import sys,json;print(json.load(sys.stdin).get("language",""))' 2>/dev/null)"
    T_WORDS="$(wc -w < "$TRANSCRIPT" | tr -d ' ')"
  else
    record_error "youtube_api_failed"
  fi
fi

# 2) other captioned web -> yt-dlp subs -> clean_subs.py (+ quality gate)
if [ "$T_SOURCE" = "none" ] && [ "$INPUT_KIND" = "url" ]; then
  log "trying captions via yt-dlp..."
  yt-dlp --no-warnings --skip-download --no-playlist "${COOKIE_ARGS[@]}" \
    --write-subs --write-auto-subs --sub-langs "en.*,sv.*" \
    -o "$DIR/sub.%(ext)s" -- "$SRC" >/dev/null 2>&1
  SUB="$(find "$DIR" -maxdepth 1 -name 'sub.en*' 2>/dev/null | head -1)"
  [ -z "$SUB" ] && SUB="$(find "$DIR" -maxdepth 1 -name 'sub.sv*' 2>/dev/null | head -1)"
  [ -z "$SUB" ] && SUB="$(find "$DIR" -maxdepth 1 \( -name 'sub*.vtt' -o -name 'sub*.srt' \) 2>/dev/null | head -1)"
  if [ -n "$SUB" ] && [ -s "$SUB" ]; then
    if "$PY" "$LIB/clean_subs.py" "$SUB" "$TRANSCRIPT" >/dev/null 2>&1 && [ -s "$TRANSCRIPT" ]; then
      T_WORDS="$(wc -w < "$TRANSCRIPT" | tr -d ' ')"
      # words/sec gate (>=0.3 wps) as integer math: T_WORDS*10 >= DURATION*3.
      # Plain bash arithmetic — no value interpolated into a python -c string.
      QUALITY_OK=1
      if [ "$DURATION" -gt 0 ] && [ "$(( T_WORDS * 10 ))" -lt "$(( DURATION * 3 ))" ]; then
        QUALITY_OK=0
      fi
      if [ "$QUALITY_OK" -eq 0 ]; then
        record_error "caption_rejected"
        : > "$TRANSCRIPT"; T_WORDS=0
      else
        T_SOURCE="captions"
        # only accept a real 2-letter language code, else leave blank
        T_LANG="$(basename "$SUB" | sed -nE 's/^sub\.([a-z]{2})([.-].*)?$/\1/p')"
      fi
    fi
  fi
fi

# 3) whisper fallback (reels / no captions / local files)
if [ "$T_SOURCE" = "none" ]; then
  if ensure_media && [ -n "$VIDEO" ] && [ -f "$VIDEO" ]; then
    if [ "$DURATION" -le 0 ]; then
      DURATION="$(ffprobe -v quiet -show_entries format=duration -of csv=p=0 "file:$VIDEO" 2>/dev/null | cut -d. -f1)"
      case "$DURATION" in ''|*[!0-9]*) DURATION=0 ;; esac
    fi
    if [ "$DURATION" -gt "$WHISPER_CAP_S" ]; then
      record_error "whisper_skipped_over_cap"
    elif [ -n "$MODELS" ] && [ -d "$MODELS" ]; then
      log "transcribing on-device (faster-whisper, language auto)..."
      ffmpeg -v quiet -y -i "file:$VIDEO" -ar 16000 -ac 1 -c:a pcm_s16le "$DIR/audio.wav" </dev/null
      if [ -s "$DIR/audio.wav" ]; then
        W_LANG="$("$PY" "$LIB/transcribe.py" "$DIR/audio.wav" "$TRANSCRIPT" "$MODELS" </dev/null 2>/dev/null)"
        if [ -s "$TRANSCRIPT" ]; then
          T_SOURCE="whisper"; T_WORDS="$(wc -w < "$TRANSCRIPT" | tr -d ' ')"
          case "$W_LANG" in [a-z][a-z]) T_LANG="$W_LANG" ;; *) T_LANG="auto" ;; esac
        else
          record_error "whisper_no_output"
        fi
      else
        record_error "no_audio"
      fi
    else
      record_error "whisper_unavailable"
    fi
  else
    note_media_failed
  fi
fi

# --- frames -----------------------------------------------------------------
F_COUNT=0; F_INTERVAL=0
if ensure_media && [ -n "$VIDEO" ] && [ -f "$VIDEO" ]; then
  if [ "$DURATION" -le 0 ]; then
    DURATION="$(ffprobe -v quiet -show_entries format=duration -of csv=p=0 "file:$VIDEO" 2>/dev/null | cut -d. -f1)"
    case "$DURATION" in ''|*[!0-9]*) DURATION=0 ;; esac
  fi
  if [ "$DURATION" -gt "$FRAME_COUNT" ]; then
    RATE="$FRAME_COUNT/$DURATION"; F_INTERVAL=$(( DURATION / FRAME_COUNT ))
  else
    RATE="1"; F_INTERVAL=1
  fi
  log "extracting frames..."
  ffmpeg -v quiet -y -i "file:$VIDEO" -vf "fps=$RATE,scale=640:-2" -frames:v "$FRAME_COUNT" \
    "$DIR/frames/frame_%03d.jpg" </dev/null
  F_COUNT="$(find "$DIR/frames" -name '*.jpg' 2>/dev/null | wc -l | tr -d ' ')"
else
  [ "$INPUT_KIND" = "url" ] && note_media_failed
fi

# --- status + companions ----------------------------------------------------
[ -f "$TRANSCRIPT" ] || : > "$TRANSCRIPT"
HAVE_T=0; { [ "$T_SOURCE" != "none" ] && [ -s "$TRANSCRIPT" ]; } && HAVE_T=1
HAVE_F=0; [ "$F_COUNT" -gt 0 ] && HAVE_F=1
if [ "$HAVE_T" -eq 1 ] && [ "$HAVE_F" -eq 1 ]; then STATUS="ok"; CODE=$EXIT_OK
elif [ "$HAVE_T" -eq 1 ] || [ "$HAVE_F" -eq 1 ]; then STATUS="partial"; CODE=$EXIT_PARTIAL
else STATUS="failed"; CODE=$EXIT_FAILED
fi

printf '%s\n' "$T_SOURCE" > "$DIR/transcript.src"
{
  echo "title: $TITLE"
  echo "channel: $CHANNEL"
  echo "duration_s: $DURATION"
  echo "upload_date: $UPLOAD_DATE"
  echo "source: $SRC"
  echo "type: $TYPE"
} > "$DIR/meta.txt"

ERR_CSV="$(IFS=,; echo "${ERRORS[*]}")"
"$PY" "$LIB/write_manifest.py" --out "$DIR/manifest.json" \
  --slug "$SLUG" --source "$SRC" --type "$TYPE" --status "$STATUS" \
  --errors "$ERR_CSV" --title "$TITLE" --channel "$CHANNEL" \
  --duration "$DURATION" --upload-date "$UPLOAD_DATE" \
  --t-source "$T_SOURCE" --t-language "$T_LANG" --t-words "$T_WORDS" \
  --frame-count "$F_COUNT" --frame-interval "$F_INTERVAL"

# --- report -----------------------------------------------------------------
echo ""
echo "=== CAPTURE $STATUS ==="
echo "dir:        $DIR"
echo "transcript: $T_WORDS words ($T_SOURCE)"
echo "frames:     $F_COUNT"
[ -n "$ERR_CSV" ] && echo "errors:     $ERR_CSV"
echo "manifest:   $DIR/manifest.json"
exit $CODE
