@preconcurrency import Foundation
import Combine
import os.log

/// Coordinates auto-recording sessions that start from meeting-window detection.
/// Runs on the main actor so UI bindings stay consistent and avoids actor hops when
/// interacting with AppKit and SwiftUI.
@MainActor
final class AutoRecordingCoordinator: ObservableObject {
    private let logger = Logger(subsystem: "com.overhear.app", category: "AutoRecordingCoordinator")
    private let stopGracePeriod: TimeInterval
    private let maxRecordingDuration: TimeInterval
    private var activeManager: MeetingRecordingManager?
    private var stopWorkItem: DispatchWorkItem?
    private var activeTitle: String?
    private var monitorTask: Task<Void, Never>?
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
        stopWorkItem?.cancel()
        stopWorkItem = nil

        if activeManager != nil {
            isRecording = true
            return // Already recording; keep going.
        }

        startRecording(appName: appName, meetingTitle: meetingTitle)
    }

    func onNoDetection() {
        guard activeManager != nil else { return }
        // Schedule a graceful stop to avoid flapping on brief focus changes.
        if stopWorkItem == nil {
            let item = DispatchWorkItem { [weak self] in
                Task { @MainActor in
                    await self?.stopRecording()
                }
            }
            stopWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + stopGracePeriod, execute: item)
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

        do {
            let manager = try MeetingRecordingManager(
                meetingID: id,
                meetingTitle: title
            )
            activeManager = manager
            onManagerUpdate?(manager)
            isRecording = true
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
        }
    }

    private func startAndMonitor(manager: MeetingRecordingManager) async {
        monitorTask = Task { [weak self, weak manager] in
            guard let manager else { return }
            await self?.monitorStatus(manager: manager)
        }
        await manager.startRecording(duration: maxRecordingDuration)
        await monitorTask?.value
    }

    private func monitorStatus(manager: MeetingRecordingManager) async {
        guard let current = activeManager, current === manager else { return }
        while !Task.isCancelled {
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
        stopWorkItem?.cancel()
        stopWorkItem = nil
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
        stopWorkItem?.cancel()
        stopWorkItem = nil
        guard let manager = activeManager else { return }
        logger.info("Auto-record stopping")
        await manager.stopRecording()
        await clearState()
    }

    func currentRecordingTitle() -> String? {
        activeTitle
    }

    deinit {
        Task { @MainActor [stopWorkItem, monitorTask] in
            stopWorkItem?.cancel()
            monitorTask?.cancel()
        }
    }
}
