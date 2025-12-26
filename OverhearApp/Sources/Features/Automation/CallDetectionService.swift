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
    private var pollInterval: TimeInterval
    private let axCheck: () -> Bool
    private var permissionDenied = false
    private var permissionRetryTask: Task<Void, Never>?
    private var lastNotifiedApp: String?
    private var lastNotifiedTitle: String?
    private let micMonitor = MicUsageMonitor()
    private var isMicActive = false
    private var activePollTask: Task<Void, Never>?
    private weak var autoCoordinator: AutoRecordingCoordinator?
    private weak var preferences: PreferencesService?
    private var lastAXQueryDate: Date?
    private let minAXQueryInterval: TimeInterval = 0.5

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

    private let permissionRetryDelay: TimeInterval = 5.0
    private let titleLookupTimeout: TimeInterval = 1.0
    private let maxTelemetryPerSession = 100
    private var telemetryCount = 0

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
        telemetryCount = 0
        logger.info("Call detection polling stopped")
    }

    @MainActor deinit {
        stop()
    }

    /// Best-effort retry entrypoint that attempts to start once permission becomes available.
    @discardableResult
    func retryIfAuthorized(autoCoordinator: AutoRecordingCoordinator?, preferences: PreferencesService) -> Bool {
        guard permissionDenied else { return true }
        return start(autoCoordinator: autoCoordinator, preferences: preferences)
    }

    func updatePollInterval(_ interval: TimeInterval) {
        pollInterval = max(1.0, interval)
        if pollTimer != nil {
            stop()
        }
        if let autoCoordinator, let preferences {
            telemetryCount = 0
            _ = start(autoCoordinator: autoCoordinator, preferences: preferences)
        }
    }

    private func schedulePermissionRetry(autoCoordinator: AutoRecordingCoordinator?, preferences: PreferencesService) {
        permissionRetryTask?.cancel()
        permissionRetryTask = Task.detached { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(self?.permissionRetryDelay ?? 5.0 * 1_000_000_000))
            guard let self else { return }
            await MainActor.run {
                guard self.axCheck() else { return }
                _ = self.start(autoCoordinator: autoCoordinator, preferences: preferences)
            }
        }
    }

    private func pollFrontmostApp() async {
        if let activePollTask {
            // Avoid overlapping polls; keep the latest request.
            activePollTask.cancel()
        }
        activePollTask = Task { @MainActor [weak self] in
            guard let self else { return }
        guard preferencesAllowNotifications else { return }
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier else {
            if await handleBackgroundDetection(excluding: nil) { return }
            autoCoordinator?.onNoDetection()
            logTelemetry(result: "no-app", bundleID: nil, host: nil)
            return
        }

        guard supportedMeetingBundles.contains(bundleID) else {
            lastNotifiedApp = nil
            lastNotifiedTitle = nil
            if await handleBackgroundDetection(excluding: bundleID) { return }
            autoCoordinator?.onNoDetection()
            logTelemetry(result: "unsupported-bundle", bundleID: bundleID, host: nil)
            return
        }

        // Require mic-in-use to reduce false positives.
        guard isMicActive else {
            if await handleBackgroundDetection(excluding: bundleID) { return }
            autoCoordinator?.onNoDetection()
            logTelemetry(result: "mic-inactive", bundleID: bundleID, host: nil)
            return
        }

        // Offload window inspection off the main actor to reduce AX latency on UI thread with timeout.
        let titleInfo = await withTaskGroup(of: (displayTitle: String, urlDescription: String?, redacted: String?)?.self) { group -> (displayTitle: String, urlDescription: String?, redacted: String?)? in
            group.addTask { [weak self] in
                guard let self else { return nil }
                return await self.titleInfoOffMain(for: app)
            }
            group.addTask { [weak self] in
                guard let self else { return nil }
                try? await Task.sleep(nanoseconds: UInt64(self.titleLookupTimeout * 1_000_000_000))
                return nil
            }
            return await group.next() ?? nil
        }
        guard let titleInfo else {
            if await handleBackgroundDetection(excluding: bundleID) { return }
            autoCoordinator?.onNoDetection()
            logTelemetry(result: "no-title", bundleID: bundleID, host: nil)
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
                  isSupportedBrowserHost(host) else {
                if titleInfo.urlDescription == nil {
                    logger.info("Skipped browser detection: missing URL attribute; ensure Meet tab is active")
                    NotificationHelper.sendBrowserUrlMissingIfNeeded()
                }
                autoCoordinator?.onNoDetection()
                logTelemetry(result: "browser-unsupported-host", bundleID: bundleID, host: titleInfo.redacted)
                return
            }
        }

        if isBrowser(bundleID),
           let urlDescription = titleInfo.urlDescription,
           let host = URL(string: urlDescription)?.host,
           !isSupportedBrowserHost(host) {
            autoCoordinator?.onNoDetection()
            logTelemetry(result: "browser-unsupported-host", bundleID: bundleID, host: titleInfo.redacted)
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
        logTelemetry(result: "detected", bundleID: bundleID, host: titleInfo.redacted)
        }
        await activePollTask?.value
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

    nonisolated private func activeWindowTitle(for app: NSRunningApplication) -> (displayTitle: String, urlDescription: String?, redacted: String?)? {
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
        let windowElement = window as! AXUIElement

        var titleValue: AnyObject?
        AXUIElementCopyAttributeValue(windowElement, kAXTitleAttribute as CFString, &titleValue)
        let rawTitle = titleValue as? String ?? ""

        // For browsers, try to extract the URL to distinguish meeting hosts.
        var urlDescription: String?
        var redactedURL: String?
        if let safariURL = copyURLAttribute(window: windowElement, key: kAXURLAttribute as CFString) {
            urlDescription = safariURL.normalizedForDetection()
            redactedURL = safariURL.redactedForLogging()
        } else if let chromeURL = copyURLAttribute(window: windowElement, key: "AXDocument" as CFString) {
            urlDescription = chromeURL.normalizedForDetection()
            redactedURL = chromeURL.redactedForLogging()
        }

        // Require either a title or URL.
        let displayTitle = rawTitle.isEmpty ? (urlDescription ?? "") : rawTitle
        guard !displayTitle.isEmpty else { return nil }

        // Normalize supported hosts for browsers.
        if let urlDescription,
           let url = URL(string: urlDescription),
           let host = url.host,
           isSupportedBrowserHost(host) {
            let title = host.contains("meet.google.com") ? "Google Meet" : displayTitle
            return (displayTitle: title, urlDescription: urlDescription, redacted: redactedURL)
        }

        return (displayTitle: displayTitle, urlDescription: urlDescription, redacted: redactedURL)
    }

    nonisolated private func copyURLAttribute(window: AXUIElement, key: CFString) -> String? {
        var urlValue: AnyObject?
        let status = AXUIElementCopyAttributeValue(window, key, &urlValue)
        guard status == .success else {
            logger.debug("AX URL attribute \(key) unavailable (status=\(status.rawValue))")
            return nil
        }
        if let cfValue = urlValue, CFGetTypeID(cfValue) == CFURLGetTypeID(), let url = cfValue as? URL {
            return url.absoluteString
        }
        if let urlString = urlValue as? String, let url = URL(string: urlString) {
            return url.absoluteString
        }
        return nil
    }

    private func titleInfoOffMain(for app: NSRunningApplication) async -> (displayTitle: String, urlDescription: String?, redacted: String?)? {
        let canQuery = await MainActor.run { () -> Bool in
            if let last = lastAXQueryDate, Date().timeIntervalSince(last) < minAXQueryInterval {
                return false
            }
            lastAXQueryDate = Date()
            return true
        }
        guard canQuery else { return nil }

        return await Task.detached(priority: .utility) { [weak self] in
            guard let self else { return nil }
            return self.activeWindowTitle(for: app)
        }.value
    }

    nonisolated func isSupportedBrowserHost(_ host: String) -> Bool {
        let supportedHosts = [
            "meet.google.com",
            "zoom.us",
            "us04web.zoom.us",
            "us02web.zoom.us",
            "teams.microsoft.com",
            "teams.live.com",
            "webex.com",
            "webex.com.cn"
        ]
        return supportedHosts.contains(where: { host.hasSuffix($0) })
    }

    private var preferencesAllowNotifications: Bool {
        guard let preferences else { return false }
        return (preferences.meetingNotificationsEnabled || preferences.autoRecordingEnabled)
    }

    private func isBrowser(_ bundleID: String) -> Bool {
        browserBundles.contains(bundleID)
    }

}

private extension CallDetectionService {
    func logTelemetry(result: String, bundleID: String?, host: String?) {
        guard telemetryCount < maxTelemetryPerSession else { return }
        telemetryCount += 1
        let safeHost = host ?? "unknown"
        let safeBundle = bundleID ?? "unknown"
        FileLogger.log(category: "CallDetectionTelemetry", message: "result=\(result) bundle=\(safeBundle) host=\(safeHost) mic=\(isMicActive)")
    }
}

private extension String {
    func redactedForLogging() -> String {
        guard let url = URL(string: self),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return self
        }
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.string ?? self
    }

    func normalizedForDetection() -> String {
        guard let url = URL(string: self),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return self
        }
        components.query = nil
        components.fragment = nil
        return components.string ?? self
    }
}
