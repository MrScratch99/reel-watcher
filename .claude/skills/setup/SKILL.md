---
name: setup
description: Install everything the reel watcher needs (ffmpeg, ffprobe, uv, Python 3.12, yt-dlp, faster-whisper and the speech model) into this folder's own tools/ and .venv/. Use when the user types /setup, asks to install or set it up, or when watch.sh says it is not installed.
---

# /setup

Talk to the user in the language he writes in (Swedish if unsure), in plain words. He may never have used a terminal.

1. Say, in one line, that you are installing the tools and that the first time takes a few minutes.
2. Run from the repo root, with the Bash tool's `timeout` set to **600000** ms:

   ```
   bash scripts/setup.sh
   ```

3. Timed out: run the same command once more (it continues where it stopped). A second timeout: tell him the connection is slow and to type /setup again later.
4. Exit 0 (last line `Klart! Allt är installerat.`): tell him it is done and that he can now paste a link with `/watch <link>`. Instagram reels that need a login: the first time, /watch will ask which browser he is logged in with.
5. Failure: explain the `Fel:` line in plain words and what to do. Do not paste the raw log. Common: no internet (check the connection, run /setup again); a broken download (run /setup again); not an Apple Silicon Mac or macOS older than 14 (this tool cannot run on that Mac).

Never use `sudo`, Homebrew, `pip install` or any global install, never ask for an admin password, and never edit `scripts/setup.sh` to get past an error.
