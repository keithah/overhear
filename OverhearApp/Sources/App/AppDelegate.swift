import AppKit
import UserNotifications
import Foundation
import SwiftUI
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var context: AppContext?
    var menuBarController: MenuBarController?
    let recordingOverlay = RecordingOverlayController()
    private var notificationDeduper = NotificationDeduper(maxEntries: 200)
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        bootstrapFileLoggingFlag()

        // Default to accessory menubar mode; CalendarService will temporarily promote if needed.
        NSApp.setActivationPolicy(.accessory)

        // Request notification permissions
        NotificationHelper.requestPermission()

        let context = AppContext.makeDefault()
        self.context = context

        // Proactively warm the MLX model so summaries/prompts are ready sooner (best-effort).
        Task {
            await LocalLLMPipeline.shared.warmup()
        }

        // Request calendar permissions with proper app focus; retry once if needed.
        Task { @MainActor in
            await requestCalendarAccessWithActivation(context: context, retryDelay: 1.0)
        }

        let controller = MenuBarController(viewModel: context.meetingViewModel,
                                           preferencesWindowController: context.preferencesWindowController,
                                           preferences: context.preferencesService,
                                           recordingCoordinator: context.recordingCoordinator,
                                           autoRecordingCoordinator: context.autoRecordingCoordinator)
        controller.setup()
        context.menuBarController = controller

        // Hotkeys (system-wide via global monitor)
        context.hotkeyManager = HotkeyManager(
            preferences: context.preferencesService,
            toggleAction: { controller.togglePopoverAction() },
            joinNextAction: { Task { await context.meetingViewModel.joinNextUpcoming() } }
        )

        // Keep strong reference to controller
        self.menuBarController = controller

        // Meeting window detection for notifications + auto-record (requires Accessibility)
        context.callDetectionService.start(autoCoordinator: context.autoRecordingCoordinator, preferences: context.preferencesService)
        context.preferencesService.$detectionPollingInterval
            .receive(on: RunLoop.main)
            .sink { [weak context] interval in
                context?.callDetectionService.updatePollInterval(interval)
            }
            .store(in: &cancellables)

        // Recording overlay to surface in-meeting status
        context.recordingCoordinator.onRecordingStatusChange = { [weak self, weak context] isRecording, title in
            guard let self else { return }
            if isRecording {
                recordingOverlay.show(title: title ?? "Recording", mode: "Manual recording")
            } else if context?.autoRecordingCoordinator.isRecording != true {
                recordingOverlay.hide()
            }
        }
        context.autoRecordingCoordinator.onStatusUpdate = { [weak self, weak context] title, active in
            guard let self else { return }
            if active {
                recordingOverlay.show(title: title, mode: "Auto recording")
            } else if context?.recordingCoordinator.isRecording != true {
                recordingOverlay.hide()
            }
        }

        // Keep windows hidden but present for proper event delivery to menubar
        DispatchQueue.main.async {
            NSApp.windows.forEach { $0.orderOut(nil) }
        }
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        menuBarController?.tearDown()
        context?.callDetectionService.stop()
        recordingOverlay.hide()
    }

    @MainActor
    private func requestCalendarAccessWithActivation(context: AppContext, retryDelay: TimeInterval) async {
        let granted = await context.calendarService.requestAccessIfNeeded()

        if granted {
            await context.meetingViewModel.reload()
        } else {
            // Only retry if the system still reports notDetermined (dialog might be delayed).
            let status = context.calendarService.authorizationStatus
            if status == .notDetermined {
                try? await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
                let secondAttempt = await context.calendarService.requestAccessIfNeeded()
                if secondAttempt {
                    await context.meetingViewModel.reload()
                }
            }
        }
    }

    private func bootstrapFileLoggingFlag() {
        let defaults = UserDefaults.standard

        // Persist file logging if enabled via environment so Finder/Spotlight launches keep logging.
        if ProcessInfo.processInfo.environment["OVERHEAR_FILE_LOGS"] == "1" {
            defaults.set(true, forKey: "overhear.enableFileLogs")
        }

        // Default to disabled unless explicitly opted-in.
        if defaults.object(forKey: "overhear.enableFileLogs") == nil {
            defaults.set(false, forKey: "overhear.enableFileLogs")
        }
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let notificationID = response.notification.request.identifier
        let shouldHandle = await MainActor.run { () -> Bool in
            return notificationDeduper.record(notificationID)
        }
        guard shouldHandle else { return }

        let actionIdentifier = response.actionIdentifier
        let content = response.notification.request.content
        let appName: String = {
            if let name = (content.userInfo["appName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !name.isEmpty {
                return name
            }
            NSLog("Overhear: Expected 'appName' in notification userInfo but none was found; falling back to notification title.")
            return content.title
        }()
        let rawMeetingTitle = (content.userInfo["meetingTitle"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? content.body
        let meetingTitle = NotificationHelper.cleanMeetingTitle(from: rawMeetingTitle)

        await MainActor.run { [weak self] in
            guard let self, let context = context else { return }
            if actionIdentifier == "com.overhear.notification.start" || actionIdentifier == UNNotificationDefaultActionIdentifier {
                context.autoRecordingCoordinator.onDetection(appName: appName, meetingTitle: meetingTitle)
            } else if actionIdentifier == "com.overhear.notification.dismiss" {
                context.autoRecordingCoordinator.onNoDetection()
            }
        }
    }
}

@MainActor
private extension AppDelegate {
    // Additional helpers can live here
}

@MainActor
final class NotificationDeduper {
    private var handled: Set<String> = []
    private var order: [String] = []
    private var timestamps: [String: Date] = [:]
    let maxEntries: Int
    let ttl: TimeInterval
    private let dateProvider: () -> Date
    private var cleanupTask: Task<Void, Never>?

    init(maxEntries: Int, ttl: TimeInterval = 60 * 60, dateProvider: @escaping () -> Date = { Date() }) {
        let hardCap = 500
        self.maxEntries = min(max(maxEntries, 1), hardCap)
        self.ttl = max(1, ttl)
        self.dateProvider = dateProvider
        startCleanupTimer()
    }

    deinit {
        cleanupTask?.cancel()
        cleanupTask = nil
    }

    func record(_ id: String) -> Bool {
        if handled.contains(id) { return false }
        handled.insert(id)
        order.append(id)
        timestamps[id] = dateProvider()
        pruneExpired()
        while order.count > maxEntries, let oldest = order.first {
            order.removeFirst()
            handled.remove(oldest)
            timestamps.removeValue(forKey: oldest)
        }
        return true
    }

    private func pruneExpired() {
        let now = dateProvider()
        order = order.filter { id in
            guard let ts = timestamps[id] else {
                handled.remove(id)
                return false
            }
            if now.timeIntervalSince(ts) <= ttl {
                return true
            }
            handled.remove(id)
            timestamps.removeValue(forKey: id)
            return false
        }
    }

    private func startCleanupTimer() {
        cleanupTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 600_000_000_000) // 10 minutes
                await MainActor.run {
                    self.pruneExpired()
                }
            }
        }
    }
}

// MARK: - Recording overlay (in-meeting indicator)

@MainActor
final class RecordingOverlayController: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private var hosting: NSHostingController<RecordingOverlayView>?

    func show(title: String, mode: String) {
        let panel = ensurePanel()
        hosting?.rootView = RecordingOverlayView(title: title, mode: mode)
        position(panel: panel)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let content = RecordingOverlayView(title: "Recording", mode: "Status")
        let hosting = NSHostingController(rootView: content)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 96),
            styleMask: [.nonactivatingPanel, .hudWindow],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.titleVisibility = .hidden
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.contentView = hosting.view
        panel.isMovableByWindowBackground = false
        panel.delegate = self

        self.panel = panel
        self.hosting = hosting
        return panel
    }

    private func position(panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let panelSize = panel.frame.size
        let x = screen.visibleFrame.maxX - panelSize.width - 20
        let y = screen.visibleFrame.maxY - panelSize.height - 60
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    func windowWillClose(_ notification: Notification) {
        panel = nil
        hosting = nil
    }
}

private struct RecordingOverlayView: View {
    let title: String
    let mode: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .foregroundColor(.red)
                Text(mode)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.primary)
                Spacer()
                Circle()
                    .fill(Color.red)
                    .frame(width: 10, height: 10)
                    .overlay(Circle().stroke(Color.white.opacity(0.6), lineWidth: 1))
            }
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.primary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Recording in progress")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.9))
                .shadow(color: Color.black.opacity(0.25), radius: 8, x: 0, y: 4)
        )
        .frame(width: 240, alignment: .leading)
    }
}
