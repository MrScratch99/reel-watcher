#!/bin/bash
# /setup: installs uv, ffmpeg, ffprobe, Python 3.12, the project packages
# (yt-dlp, faster-whisper) and the speech model into this repo's own tools/ and
# .venv/ folders. No admin password, no Homebrew, no shell profile edits. Safe
# to run again: anything already in place and verified is skipped.
# Taken from the video-editor's setup (same pinned downloads).
#
#   bash scripts/setup.sh                 install (prints one Swedish line per step)
#
# Must run on macOS's bash 3.2: no associative arrays, no mapfile.
set -euo pipefail

UV_VERSION="0.12.18"
UV_BASE="https://github.com/astral-sh/uv/releases/download/${UV_VERSION}"
FFMPEG_VERSION="9.0.2"
FFMPEG_BASE_ARM64="https://ffmpeg.martin-riedl.de/download/macos/arm64/1789931890_9.0.2"
FFMPEG_BASE_AMD64="https://ffmpeg.martin-riedl.de/download/macos/amd64/1789931006_9.0.2"
PYTHON_VERSION="3.12"
ATTEMPTS=3

# Pinned sha256 of each download ("pkg") and of the one program taken out of it
# ("bin", before any codesign). Fetched 2026-10-31 and cross-checked:
# - ffmpeg/ffprobe zips: equal to the pinned URL + .sha256 and to the downloaded zip.
# - uv archives: equal to the GitHub release's .sha256, to the checksums embedded
#   in https://astral.sh/uv/0.12.18/install.sh, and to the downloaded archive.
#   (setup does not run install.sh: it skips its own check where sha256sum is missing.)
pinned_sha256() { # <arm64|amd64> <uv|ffmpeg|ffprobe> <pkg|bin>
  case "$1/$2/$3" in
    arm64/uv/pkg) echo "cf40e0c6a202190ccd9e0406dcfdd5b2d6668a9a5c779b17948963df32aafe5b" ;;
    arm64/uv/bin) echo "17914b3f58e645361bf68424cbc71d834a96a7ada71625b28776bd7c3760afb0" ;;
    amd64/uv/pkg) echo "2e4108f5395397c8bc5d43bf83d3bdbb2d0e92b90d0efa607756be704905fa33" ;;
    amd64/uv/bin) echo "b81d99087e643205fe9851c9ab05ed4f5d6372e92a1c6499edcbbaaf3875c1d4" ;;
    arm64/ffmpeg/pkg) echo "c8ed4c4e6978a03c485edbfe4e0a5dc2380f8a30bba5150531b31b094492d924" ;;
    arm64/ffmpeg/bin) echo "2e11c6f90993cdb79fff84d3f90044d28316b310e75b3e030cfc9a54f2c9d384" ;;
    arm64/ffprobe/pkg) echo "fcbe839537485eaee7a7a8bc5cbc0f90d53617e80943e8a5b2e31cb851197ea6" ;;
    arm64/ffprobe/bin) echo "2738aa46a7f9acbc8ab09a6715554c90f7de603171ac403726765685df6a0059" ;;
    amd64/ffmpeg/pkg) echo "7c6b4125b191cbf773832dc51f424cf2b6bb7da43007d1e066f95909e47cacd4" ;;
    amd64/ffmpeg/bin) echo "b25689cf2211c0582d317e849912769a1f1c93904fe102c485b5364a425633d1" ;;
    amd64/ffprobe/pkg) echo "2322438ed2f6319a691291b247d09c69dcaa3a982460d1f269a7e1af335cfdfd" ;;
    amd64/ffprobe/bin) echo "b5df9964b0c2048318fafedcd4e3bbafbc561033cee77de8da1840685d8a9d0d" ;;
    *) return 1 ;;
  esac
}

# Every download: https only (redirects too), and an attempt ends on a stall
# (< 10 kB/s for 30 s). There is no cap on total time, so a slow but steady link
# still finishes. Three downloads on a slow link may not fit in one 10-minute
# run; downloads resume from a partial file, so a rerun continues where the
# last one stopped (see fetch_pinned).
CURL=(curl --proto '=https' --proto-redir '=https' -fsSL
      --connect-timeout 20 --speed-limit 10000 --speed-time 30)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TOOLS="$ROOT/tools"
BIN="$TOOLS/bin"
LOG="$TOOLS/setup.log"
PARTS="$TOOLS/downloads"

say() { printf '%s\n' "$*"; }

fail() {
  say "Fel: $*"
  if [ -s "$LOG" ]; then
    say "Detaljer (sista raderna i tools/setup.log):"
    tail -n 15 "$LOG" | sed 's/^/  /'
  fi
  exit 1
}

case "${1:-}" in
  "") ;;
  *)
    say "Fel: okänt val '$1'. Kör: bash scripts/setup.sh"
    exit 2
    ;;
esac

# ---------------------------------------------------------------- platform
[ "$(uname -s)" = "Darwin" ] || fail "den här installationen fungerar bara på en Mac."
case "$(uname -m)" in
  arm64) ARCH="arm64"; FFMPEG_BASE="$FFMPEG_BASE_ARM64" ;;
  *) fail "det här verktyget kräver en Mac med Apple Silicon (M1 eller senare)." ;;
esac
MACOS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
[ "${MACOS_MAJOR:-0}" -ge 14 ] || fail "det här verktyget kräver macOS 14 (Sonoma) eller senare."
command -v curl >/dev/null 2>&1 || fail "curl saknas på datorn."
command -v unzip >/dev/null 2>&1 || fail "unzip saknas på datorn."
command -v shasum >/dev/null 2>&1 || fail "shasum saknas på datorn."

mkdir -p "$BIN"
: >"$LOG"
DL="$(mktemp -d "$TOOLS/.download.XXXXXX")"
trap 'rm -rf "$DL"' EXIT

sha256_of() { shasum -a 256 "$1" | awk '{ print tolower($1) }'; }

# Swedish reason for the last failed download, from curl's exit code.
LAST_CURL_RC=0
download_problem() {
  case "$LAST_CURL_RC" in
    0) echo "filen stämde inte med den förväntade kontrollsumman (sha256)" ;;
    28) echo "nedladdningen stannade eller gick för långsamt" ;;
    6 | 7) echo "servern gick inte att nå" ;;
    *) echo "nedladdningen misslyckades" ;;
  esac
}

# Size in bytes of the file at a URL (Content-Length after redirects), or nothing.
remote_size() {
  "${CURL[@]}" --max-time 60 -I "$1" 2>>"$LOG" | tr -d '\r' |
    awk 'tolower($1) == "content-length:" { n = $2 } END { if (n ~ /^[0-9]+$/) print n }'
}

# After curl exit 22 (HTTP error), decide whether the partial file stays:
# it stays only while it is a strict prefix that can still grow (smaller than
# the server's file). A partial that is already as large as the file, or
# larger, cannot be right (its hash was checked first), so it is deleted and
# the next attempt starts fresh. If the server's size is unknown, it is
# deleted too: no attempt can then get stuck on a partial that never grows.
settle_partial() { # <url> <part> <expected sha256>
  local url="$1" part="$2" expected="$3" have total
  [ -f "$part" ] && [ ! -L "$part" ] || { rm -f "$part"; return 0; }
  [ "$(sha256_of "$part")" = "$expected" ] && return 0 # complete: used next attempt
  have="$(wc -c <"$part" | tr -d ' ')"
  total="$(remote_size "$url")"
  if [ -n "$total" ] && [ "$have" -lt "$total" ]; then
    echo "keeping partial for $url ($have of $total bytes)" >>"$LOG"
  else
    echo "deleting partial for $url ($have bytes, server size ${total:-unknown})" >>"$LOG"
    rm -f "$part"
  fi
}

# Fetch a URL to a file and check it against a pinned sha256, up to $ATTEMPTS times.
# The download goes into a stable partial file, tools/downloads/<pinned sha256>.part,
# and `curl -C -` resumes it across attempts and across reruns of setup. Nothing
# is used before the whole file matches the pinned hash; a mismatch deletes it.
fetch_pinned() {
  local url="$1" dest="$2" expected="$3" attempt actual part
  part="$PARTS/$expected.part"
  mkdir -p "$PARTS"
  rm -f "$dest"
  LAST_CURL_RC=0
  for attempt in $(seq 1 "$ATTEMPTS"); do
    if [ -f "$part" ] && [ ! -L "$part" ] && [ "$(sha256_of "$part")" = "$expected" ]; then
      mv -f "$part" "$dest"
      return 0
    fi
    [ -L "$part" ] && rm -f "$part"
    LAST_CURL_RC=0
    "${CURL[@]}" -C - -o "$part" "$url" >>"$LOG" 2>&1 || LAST_CURL_RC=$?
    if [ "$LAST_CURL_RC" -eq 0 ]; then
      actual="$(sha256_of "$part")"
      if [ "$actual" = "$expected" ]; then
        mv -f "$part" "$dest"
        return 0
      fi
      echo "sha256 mismatch for $url: expected $expected, got $actual" >>"$LOG"
      rm -f "$part"
    else
      echo "curl exit $LAST_CURL_RC for $url (attempt $attempt of $ATTEMPTS)" >>"$LOG"
      case "$LAST_CURL_RC" in
        # The server refused to resume this partial: start over next time.
        33) rm -f "$part" ;;
        # An HTTP error (416 on a full partial, a 5xx, ...): keep the partial
        # only if it is still shorter than the file, so it can grow.
        22) settle_partial "$url" "$part" "$expected" ;;
        # A dropped connection or a stall: keep the partial and resume it. A
        # bad prefix cannot slip through: the finished file must match the
        # pinned sha256, and a mismatch deletes it.
        *) ;;
      esac
    fi
    [ "$attempt" -lt "$ATTEMPTS" ] && sleep $((attempt * 2))
  done
  return 1
}

# ------------------------------------------------------ uv, ffmpeg, ffprobe
# Apple Silicon refuses to run an unsigned binary. The pinned builds come signed;
# if a signature is ever missing, ad-hoc sign and record the signed file's hash
# in tools/bin/.<name>.adhoc.sha256, since signing changes the bytes.
# The record is written only here, right after signing a binary whose pre-sign
# hash matched the pin (the caller passes "pinned"). A binary that passed only
# through the record is never re-signed or re-recorded: if its signature is
# gone it fails and is downloaded again. The record sits in the same writable
# folder as the binary, so it guards against broken downloads, not against
# someone who can already write to tools/bin.
ensure_signed() { # <name> <pinned|recorded>
  local name="$1" via="$2" f="$BIN/$1"
  [ "$ARCH" = "arm64" ] || return 0
  codesign -v "$f" >/dev/null 2>&1 && return 0
  [ "$via" = "pinned" ] || return 1
  codesign -s - -f "$f" >>"$LOG" 2>&1 || return 1
  sha256_of "$f" >"$BIN/.$name.adhoc.sha256"
}

# First line of `<name> --version` / `-version` names the pinned version.
version_ok() {
  local name="$1" first
  case "$name" in
    uv)
      first="$("$BIN/uv" --version 2>/dev/null | sed -n 1p)" || return 1
      case "$first" in "uv $UV_VERSION" | "uv $UV_VERSION "*) return 0 ;; esac ;;
    *)
      first="$("$BIN/$name" -version 2>/dev/null | sed -n 1p)" || return 1
      case "$first" in "$name version $FFMPEG_VERSION-"* | "$name version $FFMPEG_VERSION "*) return 0 ;; esac ;;
  esac
  return 1
}

# Installed and verified: a regular file whose hash is the pinned one (or, on
# arm64, the one recorded right after ad-hoc signing a pinned binary), signed
# where needed, and reporting the pinned version.
bin_ok() {
  local name="$1" f="$BIN/$1" h via="pinned"
  [ -f "$f" ] && [ ! -L "$f" ] && [ -x "$f" ] || return 1
  h="$(sha256_of "$f")"
  if [ "$h" != "$(pinned_sha256 "$ARCH" "$name" bin)" ]; then
    [ "$ARCH" = "arm64" ] && [ -f "$BIN/.$name.adhoc.sha256" ] && [ ! -L "$BIN/.$name.adhoc.sha256" ] &&
      [ "$h" = "$(cat "$BIN/.$name.adhoc.sha256")" ] || return 1
    via="recorded"
  fi
  ensure_signed "$name" "$via" || return 1
  version_ok "$name"
}

# install_bin <name> <version> <url> <member path inside the archive>
install_bin() {
  local name="$1" version="$2" url="$3" member="$4"
  local pkg="$DL/$name.pkg" x="$DL/$name.x" entries listing
  if bin_ok "$name"; then
    say "$name $version: redan installerat."
    return 0
  fi
  fetch_pinned "$url" "$pkg" "$(pinned_sha256 "$ARCH" "$name" pkg)" ||
    fail "kunde inte ladda ner $name: $(download_problem), efter $ATTEMPTS försök. Kontrollera internetanslutningen och kör /setup igen."
  rm -rf "$x"
  mkdir -p "$x"
  case "$url" in
    *.zip)
      # The zip must hold exactly one entry, named like the program; extract only it.
      entries="$(unzip -Z1 "$pkg" 2>>"$LOG")" || fail "kunde inte läsa innehållet i nedladdningen av $name."
      [ "$entries" = "$member" ] || fail "nedladdningen av $name innehöll något annat än väntat."
      unzip -o -q -j "$pkg" "$member" -d "$x" >>"$LOG" 2>&1 || fail "kunde inte packa upp $name."
      ;;
    *.tar.gz)
      # Take out only the one member; its sha256 is checked below either way.
      # Listing captured first: a pipe into `grep -q` can SIGPIPE tar under pipefail.
      listing="$(tar -tzf "$pkg" 2>>"$LOG")" || fail "kunde inte läsa innehållet i nedladdningen av $name."
      grep -Fxq -- "$member" <<<"$listing" || fail "nedladdningen av $name innehöll något annat än väntat."
      tar -xzf "$pkg" -C "$x" "$member" >>"$LOG" 2>&1 || fail "kunde inte packa upp $name."
      mv "$x/$member" "$x/$name.tmp" && mv "$x/$name.tmp" "$x/$name"
      ;;
  esac
  [ -f "$x/$name" ] && [ ! -L "$x/$name" ] || fail "nedladdningen av $name innehöll inget vanligt program."
  [ "$(sha256_of "$x/$name")" = "$(pinned_sha256 "$ARCH" "$name" bin)" ] ||
    fail "$name stämde inte med den förväntade kontrollsumman (sha256)."
  chmod 755 "$x/$name"
  xattr -d com.apple.quarantine "$x/$name" >/dev/null 2>&1 || true
  rm -f "$BIN/.$name.adhoc.sha256"
  mv -f "$x/$name" "$BIN/$name"
  bin_ok "$name" || fail "$name installerades men går inte att starta."
  say "$name $version: nedladdat, kontrollerat (sha256) och installerat i tools/bin."
}

case "$ARCH" in
  arm64) UV_TRIPLE="aarch64-apple-darwin" ;;
  amd64) UV_TRIPLE="x86_64-apple-darwin" ;;
esac
install_bin uv "$UV_VERSION" "$UV_BASE/uv-$UV_TRIPLE.tar.gz" "uv-$UV_TRIPLE/uv"
install_bin ffmpeg "$FFMPEG_VERSION" "$FFMPEG_BASE/ffmpeg.zip" ffmpeg
install_bin ffprobe "$FFMPEG_VERSION" "$FFMPEG_BASE/ffprobe.zip" ffprobe

# ------------------------------------------------- Python 3.12 and packages
export UV_PYTHON_INSTALL_DIR="$TOOLS/python"
export UV_PYTHON_BIN_DIR="$TOOLS/python/bin"
export UV_CACHE_DIR="$TOOLS/cache"
export UV_MANAGED_PYTHON=1
unset VIRTUAL_ENV
(cd "$ROOT" && "$BIN/uv" sync --locked --python "$PYTHON_VERSION") >>"$LOG" 2>&1 ||
  fail "kunde inte installera Python $PYTHON_VERSION och paketen. Kontrollera internetanslutningen och kör /setup igen."
say "Python $PYTHON_VERSION och paketen (yt-dlp, faster-whisper): klara."

# ------------------------------------------------------------ speech model
"$ROOT/.venv/bin/python" "$ROOT/lib/transcribe.py" --download "$TOOLS/models" >>"$LOG" 2>&1 ||
  fail "kunde inte ladda ner taligenkänningen (Whisper). Kontrollera internetanslutningen och kör /setup igen."
say "Taligenkänning (Whisper base): klar."

mkdir -p "$ROOT/captures"

say "Klart! Allt är installerat."
