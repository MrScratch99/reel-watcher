#!/bin/bash
# Setup script for a Claude Code cloud environment, so /watch works from the
# Claude app on a phone with the computer off. Paste this whole file into
# claude.ai/code > environment selector > New environment > Setup script, with
# Network access set to Full. No repository or GitHub account is needed.
#
# Installs into /opt/reel-watcher: this repo (app/), ffmpeg (apt), yt-dlp and
# faster-whisper (venv/) and the Whisper base model (models/), then adds the
# /watch skill and a short CLAUDE.md to /root/.claude. Runs once; the
# environment cache keeps the result and refreshes it about weekly.
set -e
export DEBIAN_FRONTEND=noninteractive
BASE=/opt/reel-watcher
APP="$BASE/app"

apt-get update -qq && apt-get install -y -qq ffmpeg >/dev/null
rm -rf "$APP" && git clone -q --depth 1 https://github.com/MrScratch99/reel-watcher "$APP"
uv venv -q "$BASE/venv"
uv pip install -q --python "$BASE/venv/bin/python" -r "$APP/pyproject.toml"
"$BASE/venv/bin/python" -c "from faster_whisper import WhisperModel; WhisperModel('base', device='cpu', compute_type='int8', download_root='$BASE/models')"

mkdir -p /root/.claude/skills/watch
cp "$APP/.claude/skills/watch/SKILL.md" /root/.claude/skills/watch/SKILL.md
cat >> /root/.claude/CLAUDE.md <<'MD'

# Reel watcher
The reel watcher is installed at /opt/reel-watcher/app. When the user pastes a video or reel
link, or types /watch, follow the /watch skill and run its commands from /opt/reel-watcher/app.
Talk to him in the language he writes in (Swedish if unsure). He reads on a phone: keep it short.
MD
echo "reel-watcher: ready"
