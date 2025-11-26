# AudioSpike (ScreenCaptureKit + Mic Capture)

Minimal SwiftPM executable to mix system audio (ScreenCaptureKit) with microphone input (AVAudioEngine) and dump a WAV for transcription spikes. No AudioCap dependency.

## Build & run

```bash
cd Tools/AudioSpike
swift run AudioSpike --duration 20 --output ~/Desktop/overhear-spike.wav
```

- Requires macOS 13+ (ScreenCaptureKit).
- Prompts for Microphone + Screen Recording permissions on first run.
- Default output: `~/Desktop/overhear-spike.wav` if `--output` is omitted.

## Transcribe the spike (whisper.cpp example)

```bash
./../scripts/transcribe_spike.sh ~/Desktop/overhear-spike.wav
```

The script expects `main` from whisper.cpp (or any whisper.cpp binary) on PATH and a `ggml-base.en.bin` model (customizable via env vars in the script). It will emit `overhear-spike.txt` next to the binary’s working directory.
