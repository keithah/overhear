# OVERHEAR CODEBASE ANALYSIS

## 1. DIRECTORY STRUCTURE & FILE ORGANIZATION

### Overall Architecture
```
Sources/
├── App/                          # Application setup & initialization
│   ├── AppContext.swift         # DI container & service initialization
│   ├── AppDelegate.swift        # macOS app lifecycle
│   ├── OverhearApp.swift        # SwiftUI App entry point
│   └── Types.swift              # (Empty - reserved for future types)
│
└── Features/                     # Feature-driven organization
    ├── Audio/                   # Audio capture & transcription
    │   ├── AudioCaptureService.swift       # AudioSpike CLI wrapper
    │   ├── MeetingRecordingManager.swift   # Recording orchestration
    │   └── TranscriptionService.swift      # Whisper.cpp wrapper
    ├── Calendar/                # Calendar access & meeting fetching
    │   └── CalendarService.swift
    ├── Meetings/                # Meeting models & logic
    │   ├── Meeting.swift        # Meeting model + platform detection
    │   └── MeetingListViewModel.swift
    ├── MenuBar/                 # macOS menu bar UI
    │   ├── MenuBarController.swift
    │   ├── MenuBarContentView.swift
    │   └── MeetingRowView.swift
    ├── Preferences/             # Settings & preferences
    │   ├── PreferencesService.swift
    │   ├── PreferencesView.swift
    │   └── PreferencesWindowController.swift
    └── Transcription/           # Transcript storage & search
        ├── TranscriptStore.swift
        ├── TranscriptionView.swift
        └── TranscriptSearchView.swift
```

**Key Observation**: Feature-based directory structure promotes modularity and code organization by domain.

---

## 2. SWIFT SOURCE FILES: COUNT, TYPES & COMPLEXITY

### File Count Summary
- **Total Swift files**: 19
- **Core app files**: 4 (App/)
- **Feature modules**: 15 (Features/)

### Breakdown by Type

#### Application Layer (4 files)
| File | Lines | Type | Complexity |
|------|-------|------|-----------|
| AppContext.swift | 20 | Dependency Injection | Low |
| AppDelegate.swift | 48 | macOS Lifecycle | Low |
| OverhearApp.swift | 22 | SwiftUI Entry Point | Low |
| Types.swift | 1 | (Empty) | N/A |

#### Audio Services (3 files) - **HIGHEST COMPLEXITY**
| File | Lines | Type | Complexity |
|------|-------|------|-----------|
| AudioCaptureService.swift | 127 | Actor Service | High |
| MeetingRecordingManager.swift | 127 | Observable Manager | High |
| TranscriptionService.swift | 153 | Actor Service | **Very High** |

#### Calendar & Meetings (2 files)
| File | Lines | Type | Complexity |
|------|-------|------|-----------|
| CalendarService.swift | 96 | Service | Medium |
| Meeting.swift | 467 | Data Models + Helpers | **Very High** |
| MeetingListViewModel.swift | 148 | ViewModel | Medium |

#### UI Layer (6 files)
| File | Lines | Type | Complexity |
|------|-------|------|-----------|
| MenuBarController.swift | 294 | Controller | High |
| MenuBarContentView.swift | 223 | SwiftUI View | High |
| MeetingRowView.swift | 182 | SwiftUI Views (2) | Medium |
| PreferencesService.swift | 202 | Observable Service | Medium |
| PreferencesView.swift | 229 | SwiftUI View | Medium |
| PreferencesWindowController.swift | 34 | Window Controller | Low |

#### Transcription (3 files)
| File | Lines | Type | Complexity |
|------|-------|------|-----------|
| TranscriptStore.swift | 288 | Actor Service | **Very High** |
| TranscriptSearchView.swift | 309 | SwiftUI View + ViewModel | High |
| TranscriptionView.swift | 128 | SwiftUI View | Medium |

### Total Lines of Code: **2,816 lines** (excluding empty file)

---

## 3. DEPENDENCIES & IMPORTS

### Framework Dependencies

#### Core Frameworks (Used Throughout)
- **Foundation** - Core data types, file operations, process management
- **SwiftUI** - UI framework
- **AppKit** - macOS-specific APIs (NSWindow, NSMenuBar, NSAlert, etc.)
- **Combine** - Reactive framework for publishers/subscribers

#### EventKit
- CalendarService.swift
- Meeting.swift
- MeetingListViewModel.swift
- PreferencesView.swift
- Used for: Calendar access, event fetching, permission management

#### Security & Cryptography
- **CryptoKit** - Used in TranscriptStore.swift for AES-GCM encryption
- **Security** - Keychain access for encryption key management

#### Service Management
- **ServiceManagement** - PreferencesService.swift for "Launch at Login"

### Import Frequency Analysis
```
Foundation         : 11 files
SwiftUI            : 10 files
AppKit             : 8 files
Combine            : 5 files
EventKit           : 4 files
CryptoKit          : 1 file
Security           : 1 file
ServiceManagement  : 1 file
```

**Key Finding**: Heavy reliance on Apple frameworks with minimal external dependencies - indicates native-first architecture.

---

## 4. ARCHITECTURE PATTERNS

### 1. **MVVM (Model-View-ViewModel)**
**Used in**:
- MeetingListViewModel → MenuBarContentView
- TranscriptSearchViewModel → TranscriptSearchView
- PreferencesService → PreferencesView

**Example**:
```swift
@MainActor
final class MeetingListViewModel: ObservableObject {
    @Published private(set) var upcomingSections: [MeetingSection] = []
    @Published private(set) var pastSections: [MeetingSection] = []
    // View observes these properties
}
```

### 2. **Service Layer Pattern**
**Services**:
- CalendarService (calendar access)
- PreferencesService (settings management)
- AudioCaptureService (audio recording)
- TranscriptionService (audio transcription)
- TranscriptStore (transcript persistence)

**Characteristics**:
- Centralized responsibility
- Observable when appropriate (@MainActor)
- Actor-based for concurrent services

### 3. **Actor-Based Concurrency**
**Used for background operations**:
```swift
actor AudioCaptureService { ... }  // Process management + cancellation
actor TranscriptionService { ... } // External tool integration
actor TranscriptStore { ... }      // File I/O + encryption
```

**Benefits**: Thread-safe concurrent access without locks

### 4. **Dependency Injection**
**Container Pattern** - AppContext.swift:
```swift
@MainActor
final class AppContext: ObservableObject {
    let preferencesService: PreferencesService
    let calendarService: CalendarService
    let meetingViewModel: MeetingListViewModel
    
    init() {
        let preferences = PreferencesService()
        let calendar = CalendarService()
        self.meetingViewModel = MeetingListViewModel(
            calendarService: calendar,
            preferences: preferences
        )
    }
}
```

**Approach**: Constructor injection + container initialization

### 5. **Observable Object Pattern**
Used for reactive UI binding:
```swift
@MainActor
final class MeetingListViewModel: ObservableObject {
    @Published var upcomingSections: [MeetingSection]
    @Published var isLoading: Bool
}
```

### 6. **Reactive Binding (Combine)**
**Used in** MeetingListViewModel:
```swift
preferences.$daysAhead
    .combineLatest(preferences.$daysBack, ...)
    .sink { [weak self] _ in
        Task { await self?.reload() }
    }
    .store(in: &cancellables)
```

---

## 5. KEY SERVICES & RESPONSIBILITIES

### A. CALENDAR SERVICE (CalendarService.swift)
**Responsibility**: Calendar access & meeting fetching

**Key Methods**:
- `requestAccessIfNeeded()` - Permission handling
- `availableCalendars()` - Get user's calendars
- `fetchMeetings()` - Query events within date range
- `calendarsBySource()` - Group calendars by source

**Architecture**:
- @MainActor (UI thread only)
- Observable (publishes authorization status)
- Uses EKEventStore for EventKit integration

**Dependencies**: EventKit framework

---

### B. MEETING MODEL (Meeting.swift)
**Responsibility**: Meeting data + platform detection + holiday detection

**Key Components**:
1. **Meeting struct** (core data model)
   - Properties: id, title, startDate, endDate, url, platform, etc.
   - Conformance: Identifiable, Hashable, Codable-ready

2. **MeetingPlatform enum** (platform detection)
   - Cases: zoom, meet, teams, webex, unknown
   - Detection: URL host parsing
   - Custom URL handling: Zoom app protocol conversion

3. **HolidayDetector class** (holiday emoji assignment)
   - Strategy: Title/calendar keyword matching + date-based detection
   - Prevents false positives (don't mark "Project Sync" on July 4th as holiday)

4. **PlatformIconProvider class** (icon mapping)
   - Maps platform → system icon + brand color
   - Generic icons for phone calls, all-day events

**File Complexity**: **467 lines** - Combines model, logic, and helpers (consider refactoring)

---

### C. AUDIO CAPTURE SERVICE (AudioCaptureService.swift)
**Responsibility**: Audio recording via AudioSpike CLI tool

**Key Method**:
```swift
func startCapture(duration: TimeInterval, outputURL: URL) async throws -> URL
```

**Implementation**:
- Wraps Process for CLI tool execution
- Handles cancellation via Task.isCancellationHandler
- Manages stdout/stderr pipes
- Actor-based for thread safety

**Dependencies**: AudioSpike executable (external binary)

---

### D. TRANSCRIPTION SERVICE (TranscriptionService.swift)
**Responsibility**: Audio transcription via whisper.cpp

**Key Method**:
```swift
func transcribe(audioURL: URL) async throws -> String
```

**Implementation**:
- Wraps whisper.cpp CLI tool
- Configurable via environment variables
- Supports bundle resources or system paths
- Process management + cancellation handling
- Temp file cleanup

**File Complexity**: **153 lines** - Complex process management

---

### E. MEETING RECORDING MANAGER (MeetingRecordingManager.swift)
**Responsibility**: Orchestrates recording + transcription workflow

**State Machine**:
```
idle → capturing → transcribing → completed
                              ↘ failed
```

**Key Features**:
- Coordinates AudioCaptureService + TranscriptionService
- Observable for UI updates (@Published properties)
- Error propagation + status tracking
- Task cancellation support

---

### F. PREFERENCES SERVICE (PreferencesService.swift)
**Responsibility**: Settings persistence & management

**Stored Preferences**:
- Launch at login
- 24-hour clock format
- Calendar selection
- View mode (compact/minimalist)
- Meeting filters (include events without links, maybe events)
- Days to show (ahead/back)
- Platform-specific open behaviors (Zoom/Meet/Teams/Webex)

**Implementation**:
- UserDefaults for storage
- @Published properties for reactive binding
- didSet hooks for automatic persistence
- Keychain management for launch at login

---

### G. TRANSCRIPT STORE (TranscriptStore.swift)
**Responsibility**: Encrypted transcript persistence

**Key Features**:
- **Encryption**: AES-GCM with CryptoKit
- **Key Management**: Keychain storage
- **Search**: Full-text search with pagination
- **CRUD**: Save, retrieve, delete, search

**Methods**:
```swift
func save(_ transcript: StoredTranscript) async throws
func retrieve(id: String) async throws -> StoredTranscript
func search(query: String, limit: Int, offset: Int) async throws -> [StoredTranscript]
func transcriptsForMeeting(_ meetingID: String) async throws -> [StoredTranscript]
```

**File Complexity**: **288 lines** - Comprehensive encryption + search implementation

---

### H. MENUBAR CONTROLLER (MenuBarController.swift)
**Responsibility**: macOS menu bar integration

**Key Responsibilities**:
1. Status item setup & icon management
2. Popover presentation/dismissal
3. Click-outside detection
4. Time-based icon updates (midnight boundary)
5. Minute-based text updates
6. Preferences window integration

**Timers**:
- `iconUpdateTimer` - Updates calendar icon at midnight
- `minuteUpdateTimer` - Updates time display every minute

**Event Monitoring**: Click detection via NSEvent.addLocalMonitor

---

### I. MENU BAR CONTENT VIEW (MenuBarContentView.swift)
**Responsibility**: Popover UI content

**Features**:
- Grouped meetings by date
- Past meetings at top, upcoming below
- Scroll-to-today functionality
- Two view modes: compact & minimalist
- Dynamic height calculation
- Search/filter integration

**File Complexity**: **223 lines** - Complex layout logic with dynamic sizing

---

## 6. CRITICAL ANALYSIS AREAS FOR CODE REVIEW

### HIGH PRIORITY Issues/Review Areas

1. **Meeting.swift (467 lines)**
   - ❌ Single Responsibility Principle violated
   - Contains: data model + platform detection + holiday detection + icon mapping
   - **Recommendation**: Split into:
     - Meeting.swift (data model only)
     - MeetingPlatformDetector.swift
     - HolidayDetector.swift (move)
     - PlatformIconProvider.swift (move)

2. **Audio Services Concurrency**
   - AudioCaptureService uses DispatchQueue within async/await
   - ❓ Thread safety verification needed
   - ⚠️ Process handling during task cancellation

3. **Error Handling**
   - Inconsistent error types across services
   - Some services throw custom errors, others wrap NSError
   - **Review**: Error propagation chain

4. **Calendar Permission Handling**
   - Multiple permission requests (AppDelegate + MeetingListViewModel + PreferencesView)
   - ❓ Race conditions possible
   - **Review**: Centralize permission management

5. **UI State Management**
   - MenuBarController manages multiple timers
   - ❓ Timer cleanup on deallocation
   - ⚠️ Memory leaks if not properly invalidated

6. **File I/O Operations**
   - TranscriptStore creates directories without atomic safety
   - AudioCaptureService output directory creation could race
   - **Review**: Thread-safe file operations

7. **UserDefaults Access**
   - PreferencesService uses custom suite: "com.overhear.app"
   - CalendarService uses same suite
   - ✓ Consistent but **verify** app sandbox configuration

8. **Encryption Key Management**
   - TranscriptStore stores key in Keychain
   - ❓ Key rotation strategy?
   - ❓ Recovery if Keychain inaccessible?

9. **Process Management**
   - AudioCaptureService + TranscriptionService both use Process
   - **Review**: Process cleanup, zombie prevention

10. **Meeting.swift URL Detection**
    - Uses NSDataDetector for URL extraction
    - ⚠️ Performance impact with large event notes
    - Multiple detector instances created (not cached)

### MEDIUM PRIORITY Review Areas

11. **SwiftUI View Hierarchy**
    - MenuBarContentView: 223 lines - consider splitting
    - MeetingRowView: Has two view types in same file (normal + minimalist)
    - **Recommendation**: Extract MinimalistMeetingRowView to separate file

12. **Observable Pattern**
    - Multiple @ObservedObject in views
    - Consider using @StateObject + environment injection

13. **DateFormatting**
    - Formatters created multiple times in views
    - Should be cached/static

14. **Platform Open Behavior**
    - MeetingPlatform.openURL uses switch statement
    - Some cases are identical (browser fallthrough)
    - **Review**: Simplification possible

15. **Search Implementation**
    - TranscriptSearchViewModel creates TranscriptStore without injection
    - **Review**: DI consistency

### LOW PRIORITY Improvements

16. Localization not implemented
17. Accessibility labels missing in some views
18. No logging infrastructure
19. No analytics

---

## 7. DEPENDENCY MAP

```
AppDelegate
├── AppContext
│   ├── PreferencesService
│   ├── CalendarService
│   ├── MeetingListViewModel
│   │   ├── CalendarService
│   │   └── PreferencesService
│   └── PreferencesWindowController
│       ├── PreferencesService
│       └── CalendarService
└── MenuBarController
    ├── MeetingListViewModel
    ├── PreferencesWindowController
    └── PreferencesService

MeetingRecordingManager
├── AudioCaptureService
└── TranscriptionService

TranscriptSearchView
└── TranscriptSearchViewModel
    └── TranscriptStore

CalendarService
└── EventKit (framework)

MenuBarController
└── (handles UI updates from MeetingListViewModel)
```

---

## 8. ASYNC/AWAIT & CONCURRENCY PATTERNS

### Task-Based Concurrency
- ✅ AppDelegate uses Task for async permission requests
- ✅ MeetingListViewModel uses Task for reloading
- ✅ MenuBarController uses Task for delayed icon updates

### Actor-Based Services
- ✅ AudioCaptureService (actor) - Process management
- ✅ TranscriptionService (actor) - Whisper CLI
- ✅ TranscriptStore (actor) - File I/O + encryption

### Cancellation Handling
- ✅ AudioCaptureService cancels process on task cancellation
- ✅ TranscriptionService cancels process on task cancellation
- ✅ TranscriptSearchViewModel cancels search task

---

## 9. SECURITY CONSIDERATIONS

1. **Encryption**
   - ✅ TranscriptStore uses AES-GCM (strong)
   - ✅ Encryption key in Keychain
   - ✅ Combines ciphertext+nonce properly

2. **Permissions**
   - ✅ EventKit permissions requested
   - ✅ Notification permissions requested
   - ⚠️ Multiple permission request points (DI)

3. **File Handling**
   - ⚠️ Audio files stored in ApplicationSupport (world-readable by default on macOS)
   - ✅ Transcripts encrypted before storage

4. **User Defaults**
   - ✓ Preferences not sensitive (settings only)
   - ✓ Encryption key NOT in preferences

---

## 10. TESTING SURFACE AREA

**High Priority for Unit Tests**:
1. Meeting platform detection (70+ test cases)
2. Holiday detection (15+ test cases)
3. PreferencesService persistence
4. CalendarService event filtering
5. MeetingListViewModel date grouping
6. TranscriptStore encryption/decryption
7. TranscriptSearchViewModel search logic

**High Priority for Integration Tests**:
1. Full recording workflow (capture → transcribe)
2. Calendar sync with preferences
3. Preferences persistence roundtrip
4. Permission request flows

---

## 11. SUMMARY METRICS

| Metric | Value |
|--------|-------|
| Total Lines | 2,816 |
| Avg File Size | 148 lines |
| Largest File | Meeting.swift (467 lines) |
| Number of Actors | 3 |
| Number of Services | 6 |
| Number of ViewModels | 2 |
| Number of Views | 6+ |
| Frameworks Used | 8 |
| External Dependencies | 0 (CLI tools only) |

