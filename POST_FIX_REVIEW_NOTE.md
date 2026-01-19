Pending next PR
- Incremental speaker bucket rebuild to avoid full-map rebuilds on every diarization update in long sessions.
- Optional shared immutable buffer strategy if multiple buffer observers cause cloning overhead.
- Hardening remaining actor isolation concerns (MeetingRecordingManager, LocalLLMPipeline warmup generation) and notes save concurrent access.
- Further keychain bypass tightening (removing CI/test bypass or alternate secure test key handling) and transcript search optimization beyond newest-first early exit.
- Structural splits of oversized files (MeetingRecordingManager, MenuBarContentView) and added tests: streaming monitor edge cases, buffer observer stress, single-instance integration.
