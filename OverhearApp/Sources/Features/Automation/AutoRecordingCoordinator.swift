import Foundation
import os.log

@MainActor
final class AutoRecordingCoordinator {
    private let logger = Logger(subsystem: "com.overhear.app", category: "AutoRecordingCoordinator")
    private var activeManager: MeetingRecordingManager?
    private var stopWorkItem: DispatchWorkItem?
    private let stopGracePeriod: TimeInterval = 8.0

    var isRecording: Bool {
        activeManager != nil
    }

    func onDetection(appName: String, meetingTitle: String?) {
        // Cancel any pending stop since we have a fresh detection.
        stopWorkItem?.cancel()
        stopWorkItem = nil

        if activeManager != nil {
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
        let title = meetingTitle?.isEmpty == false ? meetingTitle! : appName

        do {
            let manager = try MeetingRecordingManager(
                meetingID: id,
                meetingTitle: title
            )
            activeManager = manager
            logger.info("Auto-record start for \(title, privacy: .public)")
            Task {
                await manager.startRecording(duration: 3600)
            }
        } catch {
            logger.error("Failed to start auto recording: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stopRecording() async {
        stopWorkItem?.cancel()
        stopWorkItem = nil
        guard let manager = activeManager else { return }
        logger.info("Auto-record stopping")
        await manager.stopRecording()
        activeManager = nil
    }
}
