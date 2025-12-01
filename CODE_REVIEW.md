# Overhear macOS App - Comprehensive Code Review

## Executive Summary
The Overhear app demonstrates good architectural patterns with SwiftUI, Combine, and async/await. However, there are several critical and moderate issues across memory management, thread safety, error handling, and resource cleanup that should be addressed before production use.

---

# CRITICAL ISSUES (Must Fix)

## 1. Timer Leak in MenuBarController
**File:** `MenuBarController.swift` (Lines 77-81)
**Severity:** CRITICAL
**Issue:** Timer scheduled in `setup()` is never retained with `self` capture, causing it to be deallocated immediately and never fire again.

```swift
// CURRENT (BROKEN)
Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
    DispatchQueue.main.async {
        self?.updateStatusItemIcon()
    }
}
// Timer is not retained and will be deallocated
```

**Fix:** Store the timer reference:
```swift
private var updateMinuteTimer: Timer?

func setup() {
    // ... existing code ...
    updateMinuteTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
        DispatchQueue.main.async {
            self?.updateStatusItemIcon()
        }
    }
}

deinit {
    updateMinuteTimer?.invalidate()
    iconUpdateTimer?.invalidate()
    if let monitor = eventMonitor {
        NSEvent.removeMonitor(monitor)
    }
}
```

---

## 2. Strong Reference Cycle in MenuBarController
**File:** `MenuBarController.swift` (Line 105)
**Severity:** CRITICAL
**Issue:** Event monitor closure captures `self` with `[weak self]` but stores the monitor in `self.eventMonitor`. If the view model or preferences hold references back to the controller, this creates a cycle.

```swift
eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
    // closure captures weak self but eventMonitor is stored in self
    // If there are circular references through viewModel/preferences, memory leak occurs
}
```

**Risk:** Monitor is created every popover open (setupClickOutsideMonitoring called each time), but old monitors may not be properly cleaned up.

**Fix:** Ensure old monitor is removed before creating new one:
```swift
private func setupClickOutsideMonitoring() {
    // Remove any existing monitor - THIS IS GOOD
    if let monitor = eventMonitor {
        NSEvent.removeMonitor(monitor)
    }
    
    // But verify it's actually being called every time
    eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
        // ... existing code ...
    }
}
```

---

## 3. Unhandled Optional in TranscriptionService
**File:** `TranscriptionService.swift` (Line 30)
**Severity:** CRITICAL
**Issue:** Force unwrapping of optional without nil check:

```swift
let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
// ↑ Force unwrap will crash if array is empty
```

**Fix:** 
```swift
guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
    // Handle error or use fallback
    return
}
```

**Affected Code:** Same pattern in `MeetingRecordingManager.swift` line 58

---

## 4. Unhandled Optional in AudioCaptureService
**File:** `AudioCaptureService.swift` (Line 96-97)
**Severity:** CRITICAL
**Issue:** Reading from pipe without checking for errors:

```swift
let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
let errorString = String(data: errorData, encoding: .utf8) ?? ""
// If readDataToEndOfFile throws or fails, app may crash
```

---

## 5. NSWorkspace Called Without MainActor Guarantee
**File:** `Meeting.swift` (Line 240)
**Severity:** CRITICAL
**Issue:** `NSWorkspace.shared.open()` is called from `openURL()` which is NOT marked as MainActor, but NSWorkspace must be called from main thread.

```swift
@MainActor
enum MeetingPlatform {
    func openURL(_ url: URL, openBehavior: OpenBehavior) -> Bool {
        // ...
        return NSWorkspace.shared.open(urlToOpen)  // NOT on @MainActor!
    }
}
```

**Fix:** Add @MainActor to method:
```swift
@MainActor
func openURL(_ url: URL, openBehavior: OpenBehavior) -> Bool {
    // ... implementation ...
}
```

---

## 6. CalendarService Missing @MainActor on NSWorkspace Usage
**File:** `CalendarService.swift` (Line 9)
**Severity:** CRITICAL
**Issue:** UserDefaults is NOT thread-safe but no synchronization is used:

```swift
@MainActor
final class CalendarService: ObservableObject {
    private static let defaults = UserDefaults(suiteName: "com.overhear.app") ?? .standard
    // UserDefaults is being accessed from potential background threads
    // and no synchronization is in place
}
```

---

# HIGH SEVERITY ISSUES

## 7. CalendarService.calendarsBySource() Contains Debug Prints
**File:** `CalendarService.swift` (Lines 55-68)
**Severity:** HIGH
**Issue:** Debug print statements should not ship to production:

```swift
print("Available calendars count: \(calendars.count)")
print("Grouped sources count: \(grouped.count)")
print("Source: \(source.title), calendars: \(cals.count)")
print("Final result count: \(result.count)")
```

**Fix:** Remove or use `#if DEBUG` guards.

---

## 8. PreferencesView Debug Logging to Desktop
**File:** `PreferencesView.swift` (Lines 15-31)
**Severity:** HIGH
**Issue:** Writes debug logs to user's Desktop - inappropriate for production:

```swift
private func writeToLog(_ message: String) {
    let logPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Desktop/overhear_debug.log")
    // Writes to Desktop - very intrusive!
}
```

**Fix:** Remove or use proper logging framework (OSLog).

---

## 9. Missing Error Handling in MenuBarController.setup()
**File:** `MenuBarController.swift` (Lines 64-72)
**Severity:** HIGH
**Issue:** Polling loop with no timeout mechanism and silent failures:

```swift
Task { @MainActor in
    var attempts = 0
    while viewModel.upcomingSections.isEmpty && viewModel.pastSections.isEmpty && attempts < 50 {
        try? await Task.sleep(nanoseconds: 100_000_000)  // Swallowing error
        attempts += 1
    }
    self.updateStatusItemIcon()
}
```

**Issues:**
- `try?` swallows potential errors
- 50 attempts × 100ms = 5 seconds blocking on startup
- No feedback if data never loads

**Fix:** Use proper async/await with timeout:
```swift
Task { @MainActor in
    do {
        try await Task.sleep(nanoseconds: 500_000_000) // 0.5s timeout
        self.updateStatusItemIcon()
    } catch is CancellationError {
        // Task was cancelled
    } catch {
        print("Failed to wait for initial data: \(error)")
        self.updateStatusItemIcon() // Update anyway
    }
}
```

---

## 10. Duplicate Code - HolidayDetector
**File:** `Meeting.swift` (Lines 27-99) vs `HolidayDetector.swift` (entire file)
**Severity:** HIGH
**Issue:** HolidayDetector logic is duplicated in two files:
- `HolidayDetector.swift` (82 lines)
- `Meeting.swift` (73 lines with significant differences)

This creates maintenance burden and inconsistent behavior.

**Fix:** Remove duplicate from `Meeting.swift`, import from `HolidayDetector.swift`.

---

## 11. Duplicate Code - PlatformIconProvider
**File:** `Meeting.swift` (Lines 103-167) vs `PlatformIconProvider.swift` (entire file)
**Severity:** HIGH
**Issue:** `PlatformIconProvider` is defined in two files with nearly identical code.

**Fix:** Use single source of truth.

---

## 12. FileHandle Not Properly Closed
**File:** `PreferencesView.swift` (Lines 22-25)
**Severity:** HIGH
**Issue:** FileHandle opened but not guaranteed to be closed on error path:

```swift
if let fileHandle = try? FileHandle(forWritingTo: logPath) {
    fileHandle.seekToEndOfFile()
    fileHandle.write(data)
    fileHandle.closeFile()  // ← Only called if write succeeds
}
```

**Fix:** Use defer:
```swift
if let fileHandle = try? FileHandle(forWritingTo: logPath) {
    defer { fileHandle.closeFile() }
    fileHandle.seekToEndOfFile()
    fileHandle.write(data)
}
```

---

## 13. Missing Empty State for Loading in MenuBarContentView
**File:** `MenuBarContentView.swift` (Lines 22-24)
**Severity:** HIGH
**Issue:** Good empty state exists but no differentiation between "loading" and "no meetings" to user.

```swift
if viewModel.isLoading {
    HStack { Spacer(); ProgressView().scaleEffect(0.7); Spacer() }
        .frame(height: 32)
} else if allMeetings.isEmpty {
    Text("No meetings")
    // ...
}
```

**Better:** Show "Loading..." text during loading state:
```swift
if viewModel.isLoading {
    HStack { 
        Spacer()
        VStack(spacing: 8) {
            ProgressView()
            Text("Loading meetings...").font(.system(size: 11))
        }
        Spacer() 
    }
    .frame(height: 32)
} else if allMeetings.isEmpty {
    // ...
}
```

---

# MODERATE SEVERITY ISSUES

## 14. Weak Self Capture in MeetingListViewModel
**File:** `MeetingListViewModel.swift` (Line 26)
**Severity:** MODERATE
**Issue:** Weak self in reactive chain could lead to silent failures:

```swift
preferences.$daysAhead
    .combineLatest(preferences.$daysBack, preferences.$showEventsWithoutLinks, preferences.$showMaybeEvents)
    .combineLatest(preferences.$selectedCalendarIDs)
    .sink { [weak self] _ in
        Task { await self?.reload() }  // reload() silently fails if self is nil
    }
    .store(in: &cancellables)
```

**Impact:** If ViewModel is deallocated before preferences change, the reload is silently skipped.

**Better approach:** Use `[unowned self]` since ViewModel manages the subscription or ensure ViewModel lives as long as needed.

---

## 15. NSDataDetector Exception Handling
**File:** `Meeting.swift` (Lines 399, 420)
**Severity:** MODERATE
**Issue:** NSDataDetector creation can throw but error is silently discarded:

```swift
guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
    return nil
}
// If NSDataDetector creation fails, silently returns nil
// No logging of the error
```

**Better:** Log the error:
```swift
guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
    print("Failed to create NSDataDetector: \(error)")
    return nil
}
```

---

## 16. Continuation Could Be Resumed Multiple Times
**File:** `TranscriptionService.swift` (Lines 92-106)
**Severity:** MODERATE
**Issue:** Potential for multiple resume calls in continuation:

```swift
queue.async {
    process.waitUntilExit()
    
    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
    
    if process.terminationStatus != 0 {
        continuation.resume(throwing: error)
    } else {
        continuation.resume(returning: outputURL)
    }
}
```

**Risk:** If process.waitUntilExit() or readDataToEndOfFile() takes very long or errors, continuation might be resumed multiple times.

**Fix:** Add safety check:
```swift
var finished = false
queue.async {
    guard !finished else { return }
    process.waitUntilExit()
    
    finished = true
    // ... rest of code ...
}
```

---

## 17. Task.sleep Error Ignored in PreferencesView
**File:** `PreferencesView.swift` (Line 46)
**Severity:** MODERATE
**Issue:** Silently ignoring Task cancellation:

```swift
try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
// If task is cancelled, this is silently ignored
// Then loadCalendars() is called anyway
```

**Better:** Check for cancellation:
```swift
do {
    try await Task.sleep(nanoseconds: 500_000_000)
} catch is CancellationError {
    return
}
await loadCalendars()
```

---

## 18. Multiple Subscriptions to Same Publishers
**File:** `MenuBarContentView.swift` (Lines 59-71)
**Severity:** MODERATE
**Issue:** NotificationCenter subscription not cleaned up:

```swift
.onAppear {
    withAnimation {
        proxy.scrollTo(dateIdentifier(todayDate), anchor: .top)
    }
}
.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ScrollToToday"))) { _ in
    // This subscription is never cancelled/cleaned up
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        withAnimation {
            proxy.scrollTo(dateIdentifier(todayDate), anchor: .top)
        }
    }
}
```

**Issue:** Multiple subscriptions accumulate if view is recreated.

**Fix:** Store subscription and clean up:
```swift
private var scrollSubscription: AnyCancellable?

var body: some View {
    // ...
    .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ScrollToToday"))) { _ in
        // ...
    }
    .onDisappear {
        scrollSubscription?.cancel()
    }
}
```

---

## 19. Missing Error Handling in TranscriptStore
**File:** `TranscriptStore.swift` (Lines 54-58)
**Severity:** MODERATE
**Issue:** Directory creation failure is silently ignored:

```swift
try? FileManager.default.createDirectory(at: self.storageDirectory, withIntermediateDirectories: true)
```

**Fix:** Handle and log:
```swift
do {
    try FileManager.default.createDirectory(at: self.storageDirectory, withIntermediateDirectories: true)
} catch {
    print("Warning: Failed to create transcript storage directory: \(error)")
    // App will fail later when trying to save transcripts
}
```

---

## 20. Notification Center With String Keys
**File:** `MenuBarContentView.swift` (Lines 65, 160)
**Severity:** MODERATE
**Issue:** Using magic string for notification names instead of defined constants:

```swift
// Line 65
.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ScrollToToday")))

// Line 160
NotificationCenter.default.post(name: NSNotification.Name("ScrollToToday"), object: nil)
```

**Risk:** Typo would silently fail to post/receive.

**Fix:** Define constant:
```swift
extension NSNotification.Name {
    static let scrollToToday = NSNotification.Name("ScrollToToday")
}

// Then use:
.onReceive(NotificationCenter.default.publisher(for: .scrollToToday))
NotificationCenter.default.post(name: .scrollToToday, object: nil)
```

---

# LOW SEVERITY ISSUES & RECOMMENDATIONS

## 21. Overly Complex View - MenuBarContentView
**File:** `MenuBarContentView.swift`
**Severity:** LOW
**Issue:** View is 206 lines with complex layout logic. Should be split into subviews.

**Recommendation:** Extract into separate components:
- `MeetingListView` (meetings display)
- `DateGroupedMeetingList` (grouping logic)
- `MenuBarFooter` (buttons/menu)

---

## 22. Unused Import in Meeting.swift
**File:** `Meeting.swift`
**Severity:** LOW
**Issue:** Import `AppKit` at line 3 may not be needed (check if NSBezierPath or NSWorkspace used directly).

---

## 23. Missing Cancellation Token in TranscriptSearchViewModel
**File:** `TranscriptSearchView.swift` (Lines 256-257)
**Severity:** LOW
**Issue:** Search task can be cancelled but completion handlers might still try to update published properties:

```swift
searchTask?.cancel()
searchTask = Task {
    // If this task is cancelled while awaiting, isLoading remains true
    isLoading = true
    errorMessage = nil
    
    do {
        if searchQuery.isEmpty {
            let allTranscripts = try await store.allTranscripts()
            self.transcripts = allTranscripts  // ← Could fail if cancelled
        }
    }
}
```

**Better:** Check cancellation:
```swift
private func performSearch() {
    searchTask?.cancel()
    searchTask = Task {
        defer { isLoading = false }
        
        do {
            guard !Task.isCancelled else { return }
            
            if searchQuery.isEmpty {
                let allTranscripts = try await store.allTranscripts()
                guard !Task.isCancelled else { return }
                self.transcripts = allTranscripts
            }
        } catch is CancellationError {
            // Expected - task was cancelled
        } catch {
            self.errorMessage = "Search failed: \(error.localizedDescription)"
        }
    }
}
```

---

## 24. No Timeout on NSWorkspace.open()
**File:** `Meeting.swift` (Line 240)
**Severity:** LOW
**Issue:** `NSWorkspace.open()` could hang, blocking main thread.

**Recommendation:** Run in background queue:
```swift
@MainActor
func openURL(_ url: URL, openBehavior: OpenBehavior) -> Bool {
    let urlToOpen: URL = // ... determine URL ...
    
    // Don't block main thread
    DispatchQueue.global(qos: .userInitiated).async {
        NSWorkspace.shared.open(urlToOpen)
    }
    
    return true  // Assume success
}
```

---

## 25. DateFormatter Created Multiple Times
**File:** `MenuBarContentView.swift` (Lines 146-150)
**Severity:** LOW
**Issue:** DateFormatter created in every method call:

```swift
private func dateIdentifier(_ date: Date) -> String {
    let formatter = DateFormatter()  // ← Created each time
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
}

private func formattedDate(_ date: Date) -> String {
    let formatter = DateFormatter()  // ← Created each time
    formatter.dateFormat = "EEEE, d MMMM"
    return formatter.string(from: date)
}
```

**Fix:** Cache formatters:
```swift
private let dateIdentifierFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
}()

private let formattedDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "EEEE, d MMMM"
    return formatter
}()
```

---

## 26. Unused State Variables in MenuBarContentView
**File:** `MenuBarContentView.swift` (Lines 9-11)
**Severity:** LOW
**Issue:** State variables `lastScrollTime` and `canScrollToPast` are defined but never used:

```swift
@State private var lastScrollTime: Date = Date()
@State private var canScrollToPast: Bool = true
@State private var lastScrollOffset: CGFloat = 0
```

**Fix:** Remove if truly unused or implement their intended functionality.

---

## 27. Incomplete Future Feature Handling
**File:** `PreferencesView.swift` (Lines 141-150)
**Severity:** LOW
**Issue:** Placeholder sections for incomplete features:

```swift
Section(header: Text("Open rules (coming soon)")) {
    Text("Configure how Overhear opens Zoom, Meet, Teams, and Webex links.")
}

Section(header: Text("Hotkeys (coming soon)")) {
    Text("Set shortcuts to open Overhear or join your next meeting.")
}
```

**Note:** "Open rules" appear to be partially implemented (OpenBehavior enum, preferences). Consider hiding incomplete UI or implementing full feature.

---

## 28. Missing Input Validation
**File:** `PreferencesService.swift` (Lines 88-91)
**Severity:** LOW
**Issue:** No validation of stepper ranges in UI, but values are constrained in PreferencesView. Should validate in model:

```swift
@Published var daysAhead: Int {
    didSet { persist(daysAhead, key: .daysAhead) }
}
// No validation that daysAhead > 0
```

---

## 29. Hardcoded Colors in PlatformIconProvider
**File:** `Meeting.swift` (Lines 109-140)
**Severity:** LOW
**Issue:** Colors are hardcoded RGB values. Should use named colors or assets:

```swift
color: NSColor(calibratedRed: 0.04, green: 0.36, blue: 1.0, alpha: 1.0)  // #0B5CFF
```

**Better:** Use asset colors or define constants:
```swift
private enum Colors {
    static let zoomBlue = NSColor(calibratedRed: 0.04, green: 0.36, blue: 1.0, alpha: 1.0)
}
```

---

## 30. Ambiguous Date Comparison
**File:** `MeetingListViewModel.swift` (Line 82)
**Severity:** LOW
**Issue:** Complex date logic that could be clearer:

```swift
let isPast = date < calendar.startOfDay(for: now) || 
             (date == calendar.startOfDay(for: now) && events.allSatisfy { $0.endDate < fiveMinutesFromNow })
```

**Better:** Extract to method:
```swift
private func isPastDate(_ date: Date, events: [Meeting], now: Date) -> Bool {
    let today = calendar.startOfDay(for: now)
    let fiveMinutesFromNow = now.addingTimeInterval(5 * 60)
    
    if date < today {
        return true
    }
    
    if date == today {
        return events.allSatisfy { $0.endDate < fiveMinutesFromNow }
    }
    
    return false
}
```

---

# SUMMARY TABLE

| Category | Count | Examples |
|----------|-------|----------|
| **CRITICAL** | 6 | Timer leak, strong ref cycle, unhandled optionals, NSWorkspace threading |
| **HIGH** | 8 | Debug logging, missing error handling, duplicate code, unclosed file handles |
| **MODERATE** | 7 | Weak self issues, silent errors, continuation safety |
| **LOW** | 9 | Code organization, performance, hardcoded values |

---

# RECOMMENDATIONS FOR PRIORITIZATION

### Immediate (Before Release)
1. Fix timer leak in MenuBarController
2. Add @MainActor to NSWorkspace calls
3. Fix force unwraps in TranscriptionService and MeetingRecordingManager
4. Remove debug logging (prints and Desktop logs)
5. Fix error handling in MenuBarController.setup()

### Short Term (Next Sprint)
1. Remove duplicate HolidayDetector and PlatformIconProvider code
2. Fix FileHandle lifecycle with defer
3. Add proper error logging for NSDataDetector
4. Fix continuation resume safety
5. Clean up NotificationCenter subscriptions

### Technical Debt (Ongoing)
1. Split large views into smaller components
2. Extract date formatting to cached properties
3. Implement proper logging framework (OSLog)
4. Improve test coverage
5. Document magic string constants (Notification names, UserDefaults keys)

