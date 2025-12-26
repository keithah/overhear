@preconcurrency import Foundation
import Combine
import os.log

/// Coordinates auto-recording sessions that start from meeting-window detection.
/// Runs on the main actor so UI bindings stay consistent and avoids actor hops when
/// interacting with AppKit and SwiftUI.
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
    private var activeManager: MeetingRecordingManager?
    private var stopTask: Task<Void, Never>?
    private var activeTitle: String?
    private var monitorTask: Task<Void, Never>?
    private var monitorStartDate: Date?
    private var state: RecordingState = .idle
    @Published private(set) var isRecording: Bool = false
    var onManagerUpdate: ((MeetingRecordingManager?) -> Void)?
    var onCompleted: (() -> Void)?
    var onStatusUpdate: ((String, Bool) -> Void)?
    weak var manualRecordingCoordinator: MeetingRecordingCoordinator?

    init(stopGracePeriod: TimeInterval = 8.0, maxRecordingDuration: TimeInterval = 4 * 3600) {
        self.stopGracePeriod = stopGracePeriod
        self.maxRecordingDuration = maxRecordingDuration
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
            break
        }

        startRecording(appName: appName, meetingTitle: meetingTitle)
    }

    func onNoDetection() {
        guard activeManager != nil, state == .recording else { return }
        // Schedule a graceful stop to avoid flapping on brief focus changes.
        if stopTask == nil {
            stopTask = Task { [weak self] in
                guard let self = self else { return }
                try? await Task.sleep(nanoseconds: UInt64(self.stopGracePeriod * 1_000_000_000))
                await self.stopRecording()
            }
        }
    }

    private func startRecording(appName: String, meetingTitle: String?) {
        let id = "detected-\(Int(Date().timeIntervalSince1970))"
        let title: String
        if let meetingTitle, !meetingTitle.isEmpty {
            title = meetingTitle
        } else {
            title = appName
        }
        activeTitle = title
        state = .starting

        do {
            let manager = try MeetingRecordingManager(
                meetingID: id,
                meetingTitle: title
            )
            activeManager = manager
            onManagerUpdate?(manager)
            isRecording = true
            state = .recording
            logger.info("Auto-record start for \(title, privacy: .public)")
            onStatusUpdate?(title, true)
            Task {
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

    private func startAndMonitor(manager: MeetingRecordingManager) async {
        monitorTask = Task { [weak self, weak manager] in
            guard let manager else { return }
            await self?.monitorStatus(manager: manager)
        }
        monitorStartDate = Date()
        await manager.startRecording(duration: maxRecordingDuration)
        await monitorTask?.value
    }

    private func monitorStatus(manager: MeetingRecordingManager) async {
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
        guard let manager = activeManager else { return }
        logger.info("Auto-record stopping")
        state = .stopping
        await manager.stopRecording()
        await clearState()
    }

    func currentRecordingTitle() -> String? {
        activeTitle
    }

    deinit {
        stopTask?.cancel()
        stopTask = nil
        monitorTask?.cancel()
        monitorTask = nil
        if let manager = activeManager {
            Task {
                await manager.stopRecording()
            }
        }
    }
}
