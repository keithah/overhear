// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Overhear",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "Overhear",
            dependencies: [],
            path: ".",
            exclude: ["Overhear.xcodeproj", "Package.swift"],
            sources: [
                "Sources/App/OverhearApp.swift",
                "Sources/App/AppDelegate.swift", 
                "Sources/App/AppContext.swift",
                "Sources/App/AppError.swift",
                "Sources/App/PermissionsService.swift",
                "Sources/Features/MenuBar/MenuBarController.swift",
                "Sources/Features/MenuBar/MenuBarContentView.swift",
                "Sources/Features/MenuBar/MeetingRowView.swift",
                "Sources/Features/MenuBar/MenuBarIconProvider.swift",
                "Sources/Features/Meetings/Meeting.swift",
                "Sources/Features/Meetings/MeetingListViewModel.swift",
                "Sources/Features/Meetings/MeetingPlatform.swift",
                "Sources/Features/Meetings/HolidayDetector.swift",
                "Sources/Features/Meetings/PlatformIconProvider.swift",
                "Sources/Features/Calendar/CalendarService.swift",
                "Sources/Features/Preferences/PreferencesService.swift",
                "Sources/Features/Preferences/PreferencesView.swift",
                "Sources/Features/Preferences/PreferencesWindowController.swift",
                "Sources/Features/Audio/AudioCaptureService.swift",
                "Sources/Features/Audio/MeetingRecordingManager.swift",
                "Sources/Features/Audio/TranscriptionService.swift",
                "Sources/Features/Transcription/TranscriptStore.swift",
                "Sources/Features/Transcription/TranscriptSearchView.swift",
                "Sources/Features/Transcription/TranscriptionView.swift"
            ]
        )
    ]
)
