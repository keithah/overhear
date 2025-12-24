import AppKit
import os.log

/// Observes the frontmost window to infer when the user is in a call and trigger
/// meeting notifications/auto-recording. Requires Accessibility permission and
/// uses microphone-in-use as a gating signal to reduce false positives.
@MainActor
final class CallDetectionService {
    private let logger = Logger(subsystem: "com.overhear.app", category: "CallDetectionService")
    private var activationObserver: NSObjectProtocol?
    private var pollTimer: Timer?
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
        "com.microsoft.edgemac",
        "company.thebrowser.Browser",  // Arc Browser
        "org.mozilla.firefox",          // Firefox
        "com.brave.Browser"              // Brave Browser
    ]
    private let browserBundles: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "com.microsoft.edgemac",
        "company.thebrowser.Browser",
        "org.mozilla.firefox",
        "com.brave.Browser"
    ]
    private lazy var nativeMeetingBundles: Set<String> = supportedMeetingBundles.subtracting(browserBundles)

    func start(autoCoordinator: AutoRecordingCoordinator?, preferences: PreferencesService) {
        guard activationObserver == nil, pollTimer == nil else { return }
        guard AXIsProcessTrusted() else {
            logger.error("Accessibility not granted; call detection will not start.")
            NotificationHelper.sendAccessibilityPermissionNeededIfNeeded()
            return
        }
        self.autoCoordinator = autoCoordinator
        self.preferences = preferences
        micMonitor.onChange = { [weak self] active in
            self?.isMicActive = active
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
        let timer = Timer(timeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.pollFrontmostApp()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        logger.info("Call detection started with activation observer")
    }

    func stop() {
        if let observer = activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            activationObserver = nil
        }
        pollTimer?.invalidate()
        pollTimer = nil
        lastNotifiedApp = nil
        lastNotifiedTitle = nil
        micMonitor.stop()
        logger.info("Call detection polling stopped")
    }

    private func pollFrontmostApp() async {
        guard preferencesAllowNotifications else { return }
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier else {
            if handleBackgroundDetection(excluding: nil) { return }
            autoCoordinator?.onNoDetection()
            return
        }

        guard supportedMeetingBundles.contains(bundleID) else {
            lastNotifiedApp = nil
            lastNotifiedTitle = nil
            if handleBackgroundDetection(excluding: bundleID) { return }
            autoCoordinator?.onNoDetection()
            return
        }

        // Require mic-in-use to reduce false positives.
        guard isMicActive else {
            if handleBackgroundDetection(excluding: bundleID) { return }
            autoCoordinator?.onNoDetection()
            return
        }

        guard let titleInfo = activeWindowTitle(for: app) else {
            if handleBackgroundDetection(excluding: bundleID) { return }
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
        let meetingInfo = titleInfo.urlDescription ?? titleInfo.displayTitle

        guard let preferences else {
            autoCoordinator?.onNoDetection()
            return
        }

        let shouldNotify = preferences.meetingNotificationsEnabled
        let shouldAutoRecord = preferences.autoRecordingEnabled

        // For browser-based Meet, require meet.google.com to reduce false positives.
        if isBrowser(bundleID) {
            guard let urlDescription = titleInfo.urlDescription,
                  let host = URL(string: urlDescription)?.host,
                  host == "meet.google.com" else {
                if titleInfo.urlDescription == nil {
                    logger.info("Skipped browser detection: missing URL attribute; ensure Meet tab is active")
                    NotificationHelper.sendBrowserUrlMissingIfNeeded()
                }
                autoCoordinator?.onNoDetection()
                return
            }
        }

        if isBrowser(bundleID),
           let urlDescription = titleInfo.urlDescription,
           let host = URL(string: urlDescription)?.host,
           host != "meet.google.com" {
            autoCoordinator?.onNoDetection()
            return
        }

        let cleanTitle = NotificationHelper.cleanMeetingTitle(from: meetingInfo)
        if shouldNotify {
            NotificationHelper.sendMeetingPrompt(appName: appName, meetingTitle: cleanTitle)
        }
        if shouldAutoRecord {
            autoCoordinator?.onDetection(appName: appName, meetingTitle: cleanTitle)
        } else {
            autoCoordinator?.onNoDetection()
        }
        logger.info("Detected meeting window for \(appName, privacy: .public) title=\(cleanTitle, privacy: .private)")
    }

    /// Fall back to detecting native meeting apps when they are running in the background
    /// (non-frontmost) but the microphone is active. This helps catch minimized/behind other
    /// windows sessions without relying on browser URL heuristics.
    private func handleBackgroundDetection(excluding bundleID: String?) -> Bool {
        guard isMicActive else { return false }
        guard let preferences else { return false }

        let candidate = NSWorkspace.shared.runningApplications.first { app in
            guard let bid = app.bundleIdentifier else { return false }
            if let bundleID, bid == bundleID { return false }
            return nativeMeetingBundles.contains(bid) && !app.isHidden && !app.isTerminated
        }

        guard let meetingApp = candidate, let detectedBundle = meetingApp.bundleIdentifier else {
            return false
        }

        let titleInfo = activeWindowTitle(for: meetingApp)
        let appName = meetingApp.localizedName ?? detectedBundle
        let meetingInfo = titleInfo?.displayTitle ?? appName
        let cleanTitle = NotificationHelper.cleanMeetingTitle(from: meetingInfo)

        // Avoid spamming the same detection repeatedly.
        if lastNotifiedApp == detectedBundle && lastNotifiedTitle == cleanTitle {
            return true
        }

        lastNotifiedApp = detectedBundle
        lastNotifiedTitle = cleanTitle

        if preferences.meetingNotificationsEnabled {
            NotificationHelper.sendMeetingPrompt(appName: appName, meetingTitle: cleanTitle)
        }
        if preferences.autoRecordingEnabled {
            autoCoordinator?.onDetection(appName: appName, meetingTitle: cleanTitle)
        } else {
            autoCoordinator?.onNoDetection()
        }
        logger.info("Background meeting detection triggered for \(appName, privacy: .public) title=\(cleanTitle, privacy: .private)")
        return true
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
        // Safe after CFTypeID check.
        let windowElement = unsafeDowncast(window, to: AXUIElement.self)

        var titleValue: AnyObject?
        AXUIElementCopyAttributeValue(windowElement, kAXTitleAttribute as CFString, &titleValue)
        let rawTitle = titleValue as? String ?? ""

        // For browsers, try to extract the URL to distinguish Meet.
        var urlDescription: String?
        if let safariURL = copyURLAttribute(window: windowElement, key: kAXURLAttribute as CFString) {
            urlDescription = safariURL
        } else if let chromeURL = copyURLAttribute(window: windowElement, key: "AXDocument" as CFString) {
            urlDescription = chromeURL
        }

        // Require either a title or URL.
        let displayTitle = rawTitle.isEmpty ? (urlDescription ?? "") : rawTitle
        guard !displayTitle.isEmpty else { return nil }

        // Only accept Meet if the URL host matches meet.google.com.
        if let urlDescription,
           let url = URL(string: urlDescription),
           let host = url.host,
           host == "meet.google.com" {
            return (displayTitle: "Google Meet", urlDescription: urlDescription)
        }

        return (displayTitle: displayTitle, urlDescription: urlDescription)
    }

    private func copyURLAttribute(window: AXUIElement, key: CFString) -> String? {
        var urlValue: AnyObject?
        let status = AXUIElementCopyAttributeValue(window, key, &urlValue)
        guard status == .success else { return nil }
        if let cfValue = urlValue, CFGetTypeID(cfValue) == CFURLGetTypeID() {
            if let url = cfValue as? URL {
                return url.absoluteString
            }
        }
        if let urlString = urlValue as? String {
            return urlString
        }
        return nil
    }

    private var preferencesAllowNotifications: Bool {
        guard let preferences else { return false }
        return (preferences.meetingNotificationsEnabled || preferences.autoRecordingEnabled)
    }

    private func isBrowser(_ bundleID: String) -> Bool {
        browserBundles.contains(bundleID)
    }

}
