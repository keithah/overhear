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
    private let pollInterval: TimeInterval
    private let axCheck: () -> Bool
    private var permissionDenied = false
    private var permissionRetryTask: Task<Void, Never>?
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

    init(pollInterval: TimeInterval = 3.0, axCheck: @escaping () -> Bool = { AXIsProcessTrusted() }) {
        self.pollInterval = pollInterval
        self.axCheck = axCheck
    }

    @discardableResult
    func start(autoCoordinator: AutoRecordingCoordinator?, preferences: PreferencesService) -> Bool {
        guard activationObserver == nil, pollTimer == nil else { return true }
        guard axCheck() else {
            logger.error("Accessibility not granted; call detection will not start.")
            NotificationHelper.sendAccessibilityPermissionNeededIfNeeded()
            permissionDenied = true
            schedulePermissionRetry(autoCoordinator: autoCoordinator, preferences: preferences)
            return false
        }
        permissionDenied = false
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
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.pollFrontmostApp()
            }
        }
        RunLoop.main.add(timer, forMode: .default)
        pollTimer = timer
        logger.info("Call detection started with activation observer")
        return true
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
        permissionRetryTask?.cancel()
        permissionRetryTask = nil
        logger.info("Call detection polling stopped")
    }

    /// Best-effort retry entrypoint that attempts to start once permission becomes available.
    @discardableResult
    func retryIfAuthorized(autoCoordinator: AutoRecordingCoordinator?, preferences: PreferencesService) -> Bool {
        guard permissionDenied else { return true }
        return start(autoCoordinator: autoCoordinator, preferences: preferences)
    }

    private func schedulePermissionRetry(autoCoordinator: AutoRecordingCoordinator?, preferences: PreferencesService) {
        permissionRetryTask?.cancel()
        permissionRetryTask = Task.detached { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self else { return }
            await MainActor.run {
                guard self.axCheck() else { return }
                _ = self.start(autoCoordinator: autoCoordinator, preferences: preferences)
            }
        }
    }

    private func pollFrontmostApp() async {
        guard preferencesAllowNotifications else { return }
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier else {
            if await handleBackgroundDetection(excluding: nil) { return }
            autoCoordinator?.onNoDetection()
            return
        }

        guard supportedMeetingBundles.contains(bundleID) else {
            lastNotifiedApp = nil
            lastNotifiedTitle = nil
            if await handleBackgroundDetection(excluding: bundleID) { return }
            autoCoordinator?.onNoDetection()
            return
        }

        // Require mic-in-use to reduce false positives.
        guard isMicActive else {
            if await handleBackgroundDetection(excluding: bundleID) { return }
            autoCoordinator?.onNoDetection()
            return
        }

        // Offload window inspection off the main actor to reduce AX latency on UI thread.
        let titleInfo = await titleInfoOffMain(for: app)
        guard let titleInfo else {
            if await handleBackgroundDetection(excluding: bundleID) { return }
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
    private func handleBackgroundDetection(excluding bundleID: String?) async -> Bool {
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

        let titleInfo = await titleInfoOffMain(for: meetingApp)
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

    nonisolated private func activeWindowTitle(for app: NSRunningApplication) -> (displayTitle: String, urlDescription: String?)? {
        guard AXIsProcessTrusted() else {
            logger.error("Accessibility not granted; cannot inspect windows for \(app.bundleIdentifier ?? "unknown", privacy: .public)")
            return nil
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var focusedWindow: AnyObject?
        let status = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWindow)
        guard status == .success,
              let window = focusedWindow else {
            return nil
        }
        guard CFGetTypeID(window) == AXUIElementGetTypeID() else {
            logger.error("Focused window is not an AXUIElement")
            return nil
        }
        let windowElement = unsafeBitCast(window, to: AXUIElement.self) // Safe after CFTypeID check.

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

    nonisolated private func copyURLAttribute(window: AXUIElement, key: CFString) -> String? {
        var urlValue: AnyObject?
        let status = AXUIElementCopyAttributeValue(window, key, &urlValue)
        guard status == .success else {
            logger.debug("AX URL attribute \(key) unavailable (status=\(status.rawValue))")
            return nil
        }
        if let cfValue = urlValue, CFGetTypeID(cfValue) == CFURLGetTypeID(), let url = cfValue as? URL {
            return sanitized(url)
        }
        if let urlString = urlValue as? String, let url = URL(string: urlString) {
            return sanitized(url)
        }
        return nil
    }

    private func titleInfoOffMain(for app: NSRunningApplication) async -> (displayTitle: String, urlDescription: String?)? {
        await Task.detached { [weak self] () -> (displayTitle: String, urlDescription: String?)? in
            guard let self else { return nil }
            return self.activeWindowTitle(for: app)
        }.value
    }

    nonisolated private func sanitized(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.path = "" // Avoid logging/using room codes embedded in the path.
        components?.query = nil
        components?.fragment = nil
        if let hostOnly = components?.string {
            return hostOnly
        }
        if let host = url.host {
            return "\(url.scheme.map { "\($0)://" } ?? "")\(host)"
        }
        return url.absoluteString
    }

    private var preferencesAllowNotifications: Bool {
        guard let preferences else { return false }
        return (preferences.meetingNotificationsEnabled || preferences.autoRecordingEnabled)
    }

    private func isBrowser(_ bundleID: String) -> Bool {
        browserBundles.contains(bundleID)
    }

}
