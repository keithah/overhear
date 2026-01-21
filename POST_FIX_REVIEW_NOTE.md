Pending next PR
- Optional shared immutable buffer strategy if multiple buffer observers cause cloning overhead.
- Further keychain bypass tightening (e.g., explicit secure test key handling) and transcript search optimization/FTS (now behind OVERHEAR_ENABLE_FTS/UserDefaults enableFTS).
- Structural splits of oversized files (MeetingRecordingManager, MenuBarContentView) to be handled in a dedicated PR.
- Tests remaining: streaming monitor deeper edge cases; buffer observer stress with real tap I/O; checkpoint staleness; long-session speaker bucket profiling/logging; clearer user-facing errors/context.
- Config/docs cleanup: remaining magic numbers/rollover logging note; consolidate clamping helper usage if desired.
- Issue: add AppDelegate single-instance integration test (lock file) with proper PBX wiring.
