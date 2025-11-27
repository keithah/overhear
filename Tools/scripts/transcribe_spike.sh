#!/usr/bin/env bash
set -euo pipefail

WAV_PATH="${1:-$HOME/Desktop/overhear-spike.wav}"
WHISPER_BIN="${WHISPER_BIN:-$(command -v main || true)}"
WHISPER_MODEL="${WHISPER_MODEL:-$HOME/.cache/whisper.cpp/ggml-base.en.bin}"

if [[ ! -f "$WAV_PATH" ]]; then
  echo "WAV not found at $WAV_PATH. Run AudioSpike first." >&2
  exit 1
fi

if [[ -z "$WHISPER_BIN" ]]; then
  echo "Whisper binary not found. Point WHISPER_BIN to your whisper.cpp 'main' binary." >&2
  exit 1
fi

if [[ ! -f "$WHISPER_MODEL" ]]; then
  echo "Model not found at $WHISPER_MODEL. Set WHISPER_MODEL or download ggml-base.en.bin." >&2
  exit 1
fi

OUTPUT_PREFIX="${OUTPUT_PREFIX:-overhear-spike}"

echo "Transcribing $WAV_PATH with $WHISPER_BIN"
"$WHISPER_BIN" -m "$WHISPER_MODEL" -f "$WAV_PATH" -otxt -of "$OUTPUT_PREFIX"

echo "Transcript written to ${OUTPUT_PREFIX}.txt"
