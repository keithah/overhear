# Overhear

Overhear is a macOS menu bar app that makes your meetings effortless.

- **MVP:** Meeter-style menu bar launcher for calendar meetings.
- **Phase 1:** Granola-style live transcription + subtitle mode.
- **Phase 2:** Speaker labels, summaries, and action items.
- **Phase 3:** Local noise cancellation.
- **Phase 4:** Integrations (GitHub, Notion, Confluence, etc).

All processing is **local-first** and privacy-conscious.

## Architecture & Pipeline

### Audio capture & transcription
- `AVAudioCaptureService` is a native AVAudioEngine-based actor that captures microphone audio and hands it to `MeetingRecordingPipeline`.
- The pipeline chains transcription (Whisper by default, FluidAudio when `OVERHEAR_USE_FLUIDAUDIO=1`), diarization, and summarization before persisting transcripts via `TranscriptStore`.
- Transcripts are encrypted with AES-GCM before hitting disk so local storage never contains plaintext meeting data.
- When `OVERHEAR_FILE_LOGS=1` (or the persisted `overhear.enableFileLogs` setting) is enabled, capture startup, completion, and errors append diagnostic entries to `/tmp/overhear.log`, making it easy to verify permission dialogs and recording handoffs.

### Insights & summarization
- FluidAudio (feature-flagged for now) is the target streaming ASR/diarization pipeline on Apple Silicon; it can process PCM buffers directly from the capture service and run on the Neural Engine.
- Meeting summaries and action items are produced post-meeting by a local MLX runtime using a compact quantized model such as SmolLM2-1.7B-Instruct or Llama 3.2 1B Instruct.
- Output includes a concise summary, highlight bullets, and a JSON list of action items with owners, descriptions, and due dates.

## Screenshots

![Upcoming meetings menu](docs/screenshots/meeting-list.png)

![Open rules and shortcuts](docs/screenshots/link-rules.png)

## Roadmap

### MVP — Meeter Clone
- Menu bar upcoming meetings
- Scroll up for past meetings
- Click to join meetings
- Countdown to next meeting
- Calendar preferences
- Notifications + hotkeys
- Open rules for Zoom/Meet/Teams/Webex

### Phase 1 — Granola Clone
- Auto-start audio capture on join
- Real-time subtitles (floating window)
- Whisper-based streaming transcription
- Transcript storage and viewer

### Phase 2 — Insights
- Speaker diarization
- Meeting summaries
- Action items
- Search across transcripts

### Phase 3 — Noise Cancellation
- Local real-time noise suppression
- Optional virtual audio device

### Phase 4 — Integrations
- GitHub
- Notion
- Confluence
- Slack

## Requirements
- macOS 14+ on Apple Silicon (Big Sur or later clients may still be supported, but new AVAudio/FluidAudio flows assume macOS 14 APIs).
- Accessibility permissions for the global hotkeys.
- Calendar access so the menu bar can read/launch events, and Notification permission for reminders.
- The local MLX runtime expects small low-memory models (SmolLM2 1.7B or Llama 3.2 1B) and runs fully offline.

## Developer toggles

- `OVERHEAR_USE_FLUIDAUDIO=1` — opt into the FluidAudio transcription engine (stubbed; defaults to Whisper pipeline).
- `OVERHEAR_DISABLE_TRANSCRIPT_STORAGE=1` — run without writing transcripts to disk (search UI shows a banner).
- `OVERHEAR_FILE_LOGS=1` — append diagnostic logs to `/tmp/overhear.log` for meeting fetch/open flows and audio capture lifecycle events.
