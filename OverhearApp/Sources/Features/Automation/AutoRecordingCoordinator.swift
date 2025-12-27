@preconcurrency import Foundation
import Combine
import os.log

/// Coordinates auto-recording sessions that start from meeting-window detection.
/// Runs on the main actor so UI bindings stay consistent and avoids actor hops when
/// interacting with AppKit and SwiftUI.
typealias RecordingManagerRef = any RecordingManagerType

@MainActor
final class AutoRecordingCoordinator: ObservableObject {
    private enum RecordingState {
        case idle
        case starting
        case recording
        case stopping
    }

    private let logger = Logger(subsystem: "com.overhear.app", category: "AutoRecordingCoordinator")
    private let stopGracePeriod: TimeInterval
    private let maxRecordingDuration: TimeInterval
    private let managerFactory: @MainActor (String, String?) async throws -> RecordingManagerRef
    private var activeManager: RecordingManagerRef?
    private var stopTask: Task<Void, Never>?
    private var detectionTask: Task<Void, Never>?
    private var stopGeneration: Int = 0
    private var activeTitle: String?
    private var monitorTask: Task<Void, Never>?
    private var monitorStartDate: Date?
    private var state: RecordingState = .idle
    @Published private(set) var isRecording: Bool = false
    private var detectionGeneration: Int = 0
    var onManagerUpdate: ((RecordingManagerRef?) -> Void)?
    var onCompleted: (() -> Void)?
    var onStatusUpdate: ((String, Bool) -> Void)?
    weak var manualRecordingCoordinator: MeetingRecordingCoordinator?

    init(
        stopGracePeriod: TimeInterval = 8.0,
        maxRecordingDuration: TimeInterval = 4 * 3600,
        managerFactory: @escaping @MainActor (String, String?) async throws -> RecordingManagerRef = { id, title in
            try MeetingRecordingManager(meetingID: id, meetingTitle: title)
        }
    ) {
        self.stopGracePeriod = stopGracePeriod
        self.maxRecordingDuration = maxRecordingDuration
        self.managerFactory = managerFactory
    }

    func onDetection(appName: String, meetingTitle: String?) {
        // Skip if manual recording is active - don't interfere with user-initiated sessions
        if manualRecordingCoordinator?.isRecording == true {
            logger.info("Skipping auto-record detection; manual recording active")
            return
        }

        // Cancel any pending stop since we have a fresh detection.
        stopTask?.cancel()
        stopTask = nil

        switch state {
        case .recording:
            isRecording = true
            return
        case .starting, .stopping:
            return
        case .idle:
            state = .starting
        }

        detectionTask?.cancel()
        detectionGeneration &+= 1
        let generation = detectionGeneration
        let task: Task<Void, Never> = Task { [weak self] in
            guard let self else { return }
            guard !Task.isCancelled else { return }
            await self.startRecording(appName: appName, meetingTitle: meetingTitle, generation: generation)
        }
        detectionTask = task
    }

    func onNoDetection() {
        guard activeManager != nil, state == .recording else { return }
        // Schedule a graceful stop to avoid flapping on brief focus changes.
        if stopTask == nil {
            stopGeneration &+= 1
            let generation = stopGeneration
            stopTask = Task { [weak self] in
                guard let self = self else { return }
                guard generation == self.stopGeneration else { return }
                try? await Task.sleep(nanoseconds: UInt64(self.stopGracePeriod * 1_000_000_000))
                await self.stopRecording()
            }
        }
    }

    private func startRecording(appName: String, meetingTitle: String?, generation: Int) async {
        guard state == .starting, generation == detectionGeneration else { return }
        guard !Task.isCancelled else { return }
        let id = "detected-\(Int(Date().timeIntervalSince1970))"
        let title: String
        if let meetingTitle, !meetingTitle.isEmpty {
            title = meetingTitle
        } else {
            title = appName
        }
        activeTitle = title

        do {
            let manager = try await managerFactory(id, title)
            activeManager = manager
            onManagerUpdate?(manager)
            isRecording = true
            state = .recording
            logger.info("Auto-record start for \(title, privacy: .public)")
            onStatusUpdate?(title, true)
            Task { [weak self] in
                guard let self else { return }
                await self.startAndMonitor(manager: manager)
            }
        } catch {
            logger.error("Failed to start auto recording: \(error.localizedDescription, privacy: .public)")
            activeManager = nil
            activeTitle = nil
            isRecording = false
            state = .idle
        }
    }

    private func startAndMonitor(manager: RecordingManagerRef) async {
        monitorTask = Task { [weak self, weak manager] in
            guard let manager else { return }
            await self?.monitorStatus(manager: manager)
        }
        monitorStartDate = Date()
        await manager.startRecording(duration: maxRecordingDuration)
        if case .failed = manager.status {
            monitorTask?.cancel()
            monitorTask = nil
            await clearState(transcriptReady: false)
            return
        }
        await monitorTask?.value
    }

    private func monitorStatus(manager: RecordingManagerRef) async {
        guard let current = activeManager, current === manager else { return }
        while !Task.isCancelled {
            if let started = monitorStartDate, Date().timeIntervalSince(started) > maxRecordingDuration + 60 {
                logger.info("Auto-record monitor timeout; stopping recording")
                await stopRecording()
                return
            }
            guard let currentManager = activeManager, currentManager === manager else { return }
            let status = currentManager.status
            switch status {
            case .capturing, .transcribing:
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1s
                continue
            case .completed:
                return await clearState(transcriptReady: true)
            case .failed, .idle:
                return await clearState(transcriptReady: false)
            }
        }
    }

    private func clearState(transcriptReady: Bool = false) async {
        monitorTask?.cancel()
        monitorTask = nil
        monitorStartDate = nil
        stopTask?.cancel()
        stopTask = nil
        state = .idle
        let endedTitle = activeTitle
        let endedManager = activeManager
        activeManager = nil
        activeTitle = nil
        isRecording = false
        if endedManager != nil {
            onManagerUpdate?(nil)
        }
        if let endedTitle {
            onStatusUpdate?(endedTitle, false)
            NotificationHelper.sendRecordingCompleted(title: endedTitle, transcriptReady: transcriptReady)
        }
        onCompleted?()
    }

    func stopRecording() async {
        stopTask?.cancel()
        stopTask = nil
        guard state == .recording, let manager = activeManager else { return }
        logger.info("Auto-record stopping")
        state = .stopping
        await manager.stopRecording()
        await clearState()
    }

    func currentRecordingTitle() -> String? {
        activeTitle
    }

    @MainActor deinit {
        stopTask?.cancel()
        stopTask = nil
        monitorTask?.cancel()
        monitorTask = nil
        detectionTask?.cancel()
        detectionTask = nil
        if let manager = activeManager {
            cleanupTask = Task { [weak manager] in
                await manager?.stopRecording()
            }
        } else {
            logger.error("AutoRecordingCoordinator deinit without explicit stopRecording; ensure callers stop before releasing.")
        }
    }

    private var cleanupTask: Task<Void, Never>?
}

@MainActor
protocol RecordingManagerType: AnyObject, ObservableObject {
    var status: MeetingRecordingManager.Status { get }
    var displayTitle: String { get }
    var meetingTitle: String { get }
    var transcriptID: String? { get }
    var liveTranscript: String { get }
    var liveSegments: [LiveTranscriptSegment] { get }
    var summary: MeetingSummary? { get }
    func startRecording(duration: TimeInterval) async
    func stopRecording() async
    func regenerateSummary(template: PromptTemplate?) async
    func saveNotes(_ notes: String) async
}

extension MeetingRecordingManager: RecordingManagerType {}
