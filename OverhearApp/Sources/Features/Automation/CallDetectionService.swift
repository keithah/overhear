import AppKit
import os.log

@MainActor
final class CallDetectionService {
    private let logger = Logger(subsystem: "com.overhear.app", category: "CallDetectionService")
    private var activationObserver: NSObjectProtocol?
    private var lastNotifiedApp: String?
    private var lastNotifiedTitle: String?
    private let micMonitor = MicUsageMonitor()
    private var isMicActive = false
    private weak var autoCoordinator: AutoRecordingCoordinator?
    private weak var preferences: PreferencesService?

    // Known meeting bundle IDs (native apps) and browsers used for Meet.
    private let supportedMeetingBundles: Set<String> = [
        "us.zoom.xos",
        "com.zoom.xos",
        "com.microsoft.teams",
        "com.microsoft.teams2",
        "com.cisco.webexmeetings",
        "com.apple.Safari",
        "com.google.Chrome",
        "com.microsoft.edgemac"
    ]

    func start(autoCoordinator: AutoRecordingCoordinator?, preferences: PreferencesService) {
        guard activationObserver == nil else { return }
        self.autoCoordinator = autoCoordinator
        self.preferences = preferences
        micMonitor.onChange = { [weak self] active in
            Task { @MainActor [weak self] in
                self?.isMicActive = active
            }
        }
        micMonitor.start()
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.pollFrontmostApp()
            }
        }
        Task { @MainActor in
            await self.pollFrontmostApp()
        }
        logger.info("Call detection started with activation observer")
    }

    func stop() {
        if let observer = activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            activationObserver = nil
        }
        lastNotifiedApp = nil
        lastNotifiedTitle = nil
        micMonitor.stop()
        logger.info("Call detection polling stopped")
    }

    private func pollFrontmostApp() async {
        guard preferencesAllowNotifications else { return }
        guard AXIsProcessTrusted() else {
            logger.error("Accessibility not granted; skipping detection")
            return
        }
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier else {
            autoCoordinator?.onNoDetection()
            return
        }

        guard supportedMeetingBundles.contains(bundleID) else {
            lastNotifiedApp = nil
            lastNotifiedTitle = nil
            autoCoordinator?.onNoDetection()
            return
        }

        // Require mic-in-use to reduce false positives.
        guard isMicActive else {
            autoCoordinator?.onNoDetection()
            return
        }

        guard let titleInfo = activeWindowTitle(for: app) else {
            autoCoordinator?.onNoDetection()
            return
        }

        // Avoid spamming notifications for the same window.
        if lastNotifiedApp == bundleID && lastNotifiedTitle == titleInfo.displayTitle {
            return
        }

        lastNotifiedApp = bundleID
        lastNotifiedTitle = titleInfo.displayTitle

        let appName = app.localizedName ?? bundleID
        let body = titleInfo.urlDescription ?? titleInfo.displayTitle
        let shouldNotify = preferences?.meetingNotificationsEnabled != false
        let shouldAutoRecord = preferences?.autoRecordingEnabled == true

        let cleanTitle = NotificationHelper.cleanMeetingTitle(from: body)
        if shouldNotify {
            NotificationHelper.sendMeetingPrompt(appName: appName, meetingTitle: cleanTitle)
        }
        if shouldAutoRecord {
            autoCoordinator?.onDetection(appName: appName, meetingTitle: cleanTitle)
        } else {
            autoCoordinator?.onNoDetection()
        }
        logger.info("Detected meeting window for \(appName, privacy: .public) title=\(body, privacy: .public)")
    }

    private func activeWindowTitle(for app: NSRunningApplication) -> (displayTitle: String, urlDescription: String?)? {
        guard AXIsProcessTrusted() else {
            logger.error("Accessibility not granted; cannot inspect windows for \(app.bundleIdentifier ?? "unknown", privacy: .public)")
            return nil
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var focusedWindow: AnyObject?
        let status = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWindow)
        guard status == .success,
              let window = focusedWindow,
              CFGetTypeID(window) == AXUIElementGetTypeID() else {
            return nil
        }
        let axWindow = unsafeBitCast(window, to: AXUIElement.self)

        var titleValue: AnyObject?
        AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleValue)
        let rawTitle = titleValue as? String ?? ""

        // For browsers, try to extract the URL to distinguish Meet.
        var urlDescription: String?
        if let safariURL = copyURLAttribute(window: axWindow, key: kAXURLAttribute as CFString) {
            urlDescription = safariURL
        } else if let chromeURL = copyURLAttribute(window: axWindow, key: "AXDocument" as CFString) {
            urlDescription = chromeURL
        }

        // Require either a title or URL.
        let displayTitle = rawTitle.isEmpty ? (urlDescription ?? "") : rawTitle
        guard !displayTitle.isEmpty else { return nil }

        // Only accept Meet if the URL host matches meet.google.com.
        if let urlDescription, urlDescription.contains("meet.google.com") {
            return (displayTitle: "Google Meet", urlDescription: urlDescription)
        }

        return (displayTitle: displayTitle, urlDescription: urlDescription)
    }

    private func copyURLAttribute(window: AXUIElement, key: CFString) -> String? {
        var urlValue: AnyObject?
        let status = AXUIElementCopyAttributeValue(window, key, &urlValue)
        guard status == .success else { return nil }
        if let cfValue = urlValue, CFGetTypeID(cfValue) == CFURLGetTypeID() {
            return (cfValue as! URL).absoluteString
        }
        if let urlString = urlValue as? String {
            return urlString
        }
        return nil
    }

    private var preferencesAllowNotifications: Bool {
        preferences?.meetingNotificationsEnabled != false || preferences?.autoRecordingEnabled == true
    }

}
