import Foundation
import os.log

@MainActor
final class AutoRecordingCoordinator {
    private let logger = Logger(subsystem: "com.overhear.app", category: "AutoRecordingCoordinator")
    private var activeManager: MeetingRecordingManager?
    private var stopWorkItem: DispatchWorkItem?
    private let stopGracePeriod: TimeInterval = 8.0
    private var activeTitle: String?
    @Published private(set) var isRecording: Bool = false
    var onCompleted: (() -> Void)?

    func onDetection(appName: String, meetingTitle: String?) {
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
        let title = meetingTitle?.isEmpty == false ? meetingTitle! : appName
        activeTitle = title

        do {
            let manager = try MeetingRecordingManager(
                meetingID: id,
                meetingTitle: title
            )
            activeManager = manager
            isRecording = true
            logger.info("Auto-record start for \(title, privacy: .public)")
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
        await manager.startRecording(duration: 3600)
        // Watch until it completes/fails, then clear state.
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                // Simple polling; MeetingRecordingManager doesn't expose a delegate.
                while let status = await self?.activeManager?.status {
                    switch status {
                    case .capturing, .transcribing:
                        try? await Task.sleep(nanoseconds: 300_000_000) // 0.3s
                        continue
                    case .completed, .failed, .idle:
                        await self?.clearState()
                        return
                    }
                }
                await self?.clearState()
            }
            await group.waitForAll()
        }
    }

    private func clearState() async {
        stopWorkItem?.cancel()
        stopWorkItem = nil
        activeManager = nil
        activeTitle = nil
        isRecording = false
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
}
