#!/usr/bin/env python3
"""On-device speech-to-text with faster-whisper (no API key, nothing leaves the Mac).

Usage:
    transcribe.py <wav> <out-text-path> <models-dir>
        <wav> is 16 kHz mono 16-bit PCM (watch.sh makes it with ffmpeg). Writes the
        transcript as plain text and prints the detected language code.
    transcribe.py --download <models-dir>
        Fetches the model once (run by /setup), so a capture never downloads.

Model: WATCH_WHISPER_MODEL (default "base", multilingual, ~145 MB).
"""
from __future__ import annotations

import os
import sys
import wave

MODEL = os.environ.get("WATCH_WHISPER_MODEL", "base")


def load(models_dir: str, local_only: bool):
    from faster_whisper import WhisperModel

    return WhisperModel(MODEL, device="cpu", compute_type="int8",
                        download_root=models_dir, local_files_only=local_only)


def read_wav(path: str):
    # Decoded here rather than by faster-whisper's PyAV path, which breaks when
    # PyAV changes its open() arguments.
    import numpy as np

    with wave.open(path, "rb") as w:
        if (w.getnchannels(), w.getsampwidth(), w.getframerate()) != (1, 2, 16000):
            raise ValueError("expected 16 kHz mono 16-bit PCM")
        pcm = w.readframes(w.getnframes())
    return np.frombuffer(pcm, dtype=np.int16).astype(np.float32) / 32768.0


def main() -> int:
    if len(sys.argv) == 3 and sys.argv[1] == "--download":
        load(sys.argv[2], local_only=False)
        return 0
    if len(sys.argv) != 4:
        print(__doc__, file=sys.stderr)
        return 2
    src, out, models_dir = sys.argv[1:]
    segments, info = load(models_dir, local_only=True).transcribe(read_wav(src), language=None)
    text = "\n".join(s.text.strip() for s in segments if s.text.strip())
    with open(out, "w", encoding="utf-8") as f:
        f.write(text + ("\n" if text else ""))
    print(info.language or "")
    return 0


if __name__ == "__main__":
    sys.exit(main())
