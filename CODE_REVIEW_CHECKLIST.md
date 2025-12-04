# OVERHEAR CODE REVIEW CHECKLIST

## File-by-File Review Priorities

### 🔴 CRITICAL (Review First)

#### 1. Meeting.swift (467 lines)
- [ ] Split into separate concerns
  - [ ] Core Meeting model
  - [ ] MeetingPlatform detection
  - [ ] HolidayDetector logic
  - [ ] PlatformIconProvider
- [ ] Verify NSDataDetector performance (URL detection)
- [ ] Check holiday detection false positives
- [ ] Review Zoom URL conversion logic

#### 2. AudioCaptureService.swift (127 lines)
- [ ] Thread safety of `currentProcess` variable
- [ ] DispatchQueue within async/await context
- [ ] Process cleanup on cancellation
- [ ] Pipe read operation safety
- [ ] Error message handling

#### 3. TranscriptionService.swift (153 lines)
- [ ] Process execution and cleanup
- [ ] Temp file deletion timing
- [ ] Cancellation handling robustness
- [ ] Path resolution logic (Bundle vs System vs Env)
- [ ] Error message propagation

#### 4. TranscriptStore.swift (288 lines)
- [ ] Encryption key retrieval/creation logic
- [ ] Keychain error handling
- [ ] File I/O race conditions
- [ ] Directory creation atomicity
- [ ] Search pagination correctness

#### 5. MenuBarController.swift (294 lines)
- [ ] Timer lifecycle management (memory leaks?)
- [ ] NSEvent monitor cleanup
- [ ] Click-outside detection logic
- [ ] Icon generation on background thread?
- [ ] Popover lifecycle

---

### 🟠 HIGH PRIORITY

#### 6. MeetingListViewModel.swift (148 lines)
- [ ] Calendar permission request consolidation
- [ ] Combine subscription lifecycle
- [ ] Date grouping logic for edge cases
- [ ] Past/upcoming cutoff logic (5 min threshold)
- [ ] Error handling in reload()

#### 7. MenuBarContentView.swift (223 lines)
- [ ] Dynamic height calculation correctness
- [ ] Scroll-to-today logic
- [ ] State management for minimalist/compact modes
- [ ] Split into smaller views

#### 8. CalendarService.swift (96 lines)
- [ ] Permission request race conditions
- [ ] Calendar filtering logic
- [ ] hasAskedForPermission state machine
- [ ] macOS version compatibility

#### 9. PreferencesService.swift (202 lines)
- [ ] UserDefaults thread safety
- [ ] Launch at login error handling
- [ ] Keychain interaction
- [ ] Preference key consistency

#### 10. MeetingRecordingManager.swift (127 lines)
- [ ] State machine transitions
- [ ] Task cancellation propagation
- [ ] File path generation uniqueness
- [ ] Error recovery paths

---

### 🟡 MEDIUM PRIORITY

#### 11. PreferencesView.swift (229 lines)
- [ ] Calendar loading async flow
- [ ] Source/calendar toggle logic
- [ ] Empty state handling

#### 12. MenuBarController.swift (continued)
- [ ] Icon rendering logic (NSImage)
- [ ] Font size consistency

#### 13. TranscriptSearchView.swift (309 lines)
- [ ] Search debouncing correctness
- [ ] Pagination logic
- [ ] Error message clarity

#### 14. MeetingRowView.swift (182 lines)
- [ ] Both view variants (minimize duplication?)
- [ ] Time formatting edge cases
- [ ] Hover state handling

---

## Cross-Cutting Concerns

### Concurrency & Threading
- [ ] @MainActor usage consistency
- [ ] Actor isolation verification
- [ ] Task cancellation propagation
- [ ] DispatchQueue necessity in async code

### Error Handling
- [ ] Custom error types consistency
- [ ] Error localization for users
- [ ] Error recovery strategies
- [ ] Silent failures audit

### File I/O
- [ ] Atomic operations for recordings
- [ ] Directory creation safety
- [ ] Temp file cleanup guarantees
- [ ] Path validation

### Permissions
- [ ] Consolidate calendar permission requests
- [ ] Notification permission handling
- [ ] Permission status updates

### Memory Management
- [ ] Timer cleanup (MenuBarController)
- [ ] NSEvent monitor cleanup
- [ ] Combine subscription lifecycle
- [ ] Weak reference usage

### Performance
- [ ] NSDataDetector caching for URL detection
- [ ] DateFormatter caching
- [ ] View rendering optimization
- [ ] Search pagination limits

---

## Security Review

### Encryption
- [ ] AES-GCM implementation correctness
- [ ] Key generation entropy
- [ ] Nonce handling in encryption
- [ ] Keychain item accessibility settings

### File Security
- [ ] Audio file permissions
- [ ] Transcript storage permissions
- [ ] Temporary file cleanup

### Input Validation
- [ ] URL parsing safety
- [ ] Calendar ID validation
- [ ] User preference bounds checking

---

## Testing Coverage Areas

### Unit Tests (Priority Order)
1. [ ] MeetingPlatform.detect() - 10+ cases
2. [ ] HolidayDetector.detectHoliday() - 15+ cases
3. [ ] Meeting initialization - 5+ cases
4. [ ] PreferencesService persistence - 5+ cases
5. [ ] TranscriptStore encryption roundtrip - 3+ cases
6. [ ] CalendarService filtering - 4+ cases
7. [ ] MeetingListViewModel grouping - 3+ cases

### Integration Tests
1. [ ] Full recording → transcription flow
2. [ ] Calendar sync with preference changes
3. [ ] Permission request flows
4. [ ] Preferences persistence roundtrip

---

## Code Quality Metrics

### Cyclomatic Complexity - Files to Review
- [ ] Meeting.swift - Holiday detection has many branches
- [ ] MenuBarController.swift - Icon updates & timers
- [ ] MeetingListViewModel.swift - Date grouping logic
- [ ] TranscriptSearchView.swift - State management

### Single Responsibility Principle
- [ ] Meeting.swift - VIOLATES (split into 4 files)
- [ ] MenuBarController.swift - Multiple concerns (consider breaking down)
- [ ] MenuBarContentView.swift - Layout complexity

### DRY Principle
- [ ] MeetingRowView.swift - Two similar view types
- [ ] DateFormatter usage - Multiple identical formatters
- [ ] Permission request code - Duplicated in 3 places

---

## Documentation Gaps

- [ ] Architecture decision record (why actors vs managers?)
- [ ] API documentation for services
- [ ] Error code documentation
- [ ] Permission handling flow diagram
- [ ] Data flow for recording workflow

---

## Known Issues to Track

1. **Meeting.swift** - Too large (467 lines)
2. **Audio services** - DispatchQueue in async/await context
3. **Permission handling** - Multiple request points
4. **UI complexity** - MenuBar views could be split
5. **Search** - TranscriptStore not injected

