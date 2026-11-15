# reel-watcher

Let Claude "watch" a video. Paste an Instagram reel, TikTok, YouTube or other video link into
Claude Code, and it downloads the video on your Mac, transcribes the speech locally, looks at
about ten frames, and tells you what the video says and shows.

- Runs from the **Code tab in Claude Desktop**. No terminal, no Homebrew, no admin password.
- No API keys. Speech-to-text runs on your Mac (faster-whisper).
- Needs an **Apple Silicon Mac** (M1 or later) with **macOS 14** or later, and a Claude plan
  with the Code tab (Pro or higher).

## Snabbstart (svenska)

1. Starta en session i Code-fliken i Claude Desktop (valfri mapp) och skriv:
   > Ladda ner https://github.com/MrScratch99/reel-watcher/archive/refs/heads/main.zip med curl,
   > packa upp den i min hemmapp och döp om mappen till reel-watcher.
2. Starta en ny session med mappen `reel-watcher` i hemmappen som projektmapp. Frågar Claude om
   du litar på mappen, svara ja.
3. Skriv `/setup`. Det tar några minuter första gången.
4. Skriv `/watch` och klistra in en länk, gärna med en fråga:
   > /watch https://www.instagram.com/reel/... vad är hooken och hur är den klippt?
5. Första gången en Instagram-reel kräver inloggning frågar Claude vilken webbläsare du är
   inloggad på Instagram i. Säger macOS att något vill läsa webbläsarens inloggningar: välj Tillåt.

## Quick start (English)

1. Download the ZIP (green **Code** button, **Download ZIP**), unzip it, and move the folder to
   your home folder. Or ask Claude in any Code-tab session to download
   `https://github.com/MrScratch99/reel-watcher/archive/refs/heads/main.zip` with curl and unzip it
   into your home folder as `reel-watcher`.
2. Open that folder as the project in a new local Code-tab session. If asked whether you trust
   the folder, say yes.
3. Type `/setup`, then `/watch <link> [question]`.

## How it works

`watch.sh <link-or-file> <slug>` writes `captures/<slug>/`:

| File | What |
|---|---|
| `manifest.json` | status (`ok` / `partial` / `failed`, also the exit code 0 / 10 / 20), errors, counts |
| `transcript.txt` | YouTube: the official transcript; captioned sites: cleaned captions; reels and files: faster-whisper |
| `meta.txt` | title, channel, duration, upload date, source |
| `frames/` | about ten evenly spaced frames, 640 px wide |

After reading, `scripts/purge.sh <slug>` deletes the video, audio and frames and keeps the text.

Instagram reels that need a login use your browser's Instagram session:
`scripts/cookies.sh <browser> <reel link>` saves only the Instagram, TikTok and Facebook cookies
to `~/.config/reel-watcher/cookies.txt` (mode 600). Everything else in the browser's cookie jar is
discarded.

Video content is treated as untrusted: the `/watch` skill never follows instructions found in a
video. yt-dlp runs site-specific code with access to those cookies, so update it deliberately.

## Pinned tools

`scripts/setup.sh` downloads uv 0.12.18 and static ffmpeg/ffprobe 9.0.2 (checked against pinned
sha256), installs Python 3.12 with uv, syncs `uv.lock` (yt-dlp, youtube-transcript-api,
faster-whisper) into `.venv/`, and fetches the Whisper `base` model into `tools/models/`.
