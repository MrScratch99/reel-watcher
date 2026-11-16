#!/bin/bash
# Setup script for a Claude Code cloud environment (claude.ai/code > environment
# selector > New environment > Setup script). Paste this whole file there.
# Installs ffmpeg, yt-dlp, faster-whisper and the Whisper base model into
# /opt/reel-watcher, where watch.sh looks when the folder has no .venv. Runs
# once; the environment cache keeps the result for later sessions.
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq && apt-get install -y -qq ffmpeg >/dev/null
uv venv -q /opt/reel-watcher/venv
uv pip install -q --python /opt/reel-watcher/venv/bin/python \
  yt-dlp==2026.10.26 youtube-transcript-api==1.2.4 faster-whisper==1.2.1
/opt/reel-watcher/venv/bin/python -c "from faster_whisper import WhisperModel; WhisperModel('base', device='cpu', compute_type='int8', download_root='/opt/reel-watcher/models')"
echo "reel-watcher: ready"
