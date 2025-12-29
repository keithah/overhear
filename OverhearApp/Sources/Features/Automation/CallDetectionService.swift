import AppKit
import CoreFoundation
import os.log

/// Observes the frontmost window to infer when the user is in a call and trigger
/// meeting notifications/auto-recording. Requires Accessibility permission and
/// uses microphone-in-use as a gating signal to reduce false positives.
@MainActor
final class CallDetectionService {
    private var pollGeneration = 0
    private let logger = Logger(subsystem: "com.overhear.app", category: "CallDetectionService")
    private var activationObserver: NSObjectProtocol?
    private var pollTimer: Timer?
    private var pollInterval: TimeInterval
    private let axCheck: () -> Bool
    private var permissionDenied = false
    private var permissionRetryTask: Task<Void, Never>?
    private var lastNotifiedApp: String?
    private var lastNotifiedTitle: String?
    private var micMonitor: MicUsageMonitor?
    private var isMicActive = false
    private var activePollTask: Task<Void, Never>?
    private weak var autoCoordinator: AutoRecordingCoordinator?
    private weak var preferences: PreferencesService?
    private var lastAXQueryDate: Date?
    private let minAXQueryInterval: TimeInterval = 0.5
    private var lastMissingURLNotice: Date?
    private var permissionRetryAttempts = 0
    private let maxPermissionRetries = 3
    private var axQueryInFlight = false

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

    private var permissionRetryDelay: TimeInterval = 5.0
    private let titleLookupTimeout: TimeInterval
    private let maxTelemetryPerSession: Int
    private let idlePollingBackoffThreshold: TimeInterval = 3600 // 1 hour
    private var lastDetectionDate: Date?
    private var telemetryResetDate = Date()
    private var telemetryCount = 0

    init(pollInterval: TimeInterval = 3.0, axCheck: @escaping () -> Bool = { AXIsProcessTrusted() }) {
        self.pollInterval = pollInterval
        self.axCheck = axCheck
        self.titleLookupTimeout = UserDefaults.standard.value(forKey: "overhear.titleLookupTimeout") as? TimeInterval ?? 1.0
        let configuredTelemetryCap = UserDefaults.standard.integer(forKey: "overhear.telemetryMaxPerSession")
        self.maxTelemetryPerSession = configuredTelemetryCap.nonZeroOrDefault(500)
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
        permissionRetryAttempts = 0
        self.autoCoordinator = autoCoordinator
        self.preferences = preferences
        if micMonitor == nil {
            micMonitor = MicUsageMonitor()
        }
        micMonitor?.onChange = { [weak self] active in
            self?.isMicActive = active
        }
        micMonitor?.start()
        micMonitor?.healthCheck()
        telemetryCount = 0
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
        startTimer()
        logger.info("Call detection started with activation observer")
        return true
    }

    func stop(clearState: Bool = true) {
        if let observer = activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            activationObserver = nil
        }
        pollTimer?.invalidate()
        pollTimer = nil
        if clearState {
            lastNotifiedApp = nil
            lastNotifiedTitle = nil
            telemetryCount = 0
        }
        micMonitor?.stop()
        permissionRetryTask?.cancel()
        permissionRetryTask = nil
        logger.info("Call detection polling stopped")
    }

    private func startTimer() {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: adjustedInterval(), repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.pollFrontmostApp()
            }
        }
        RunLoop.main.add(timer, forMode: .default)
        pollTimer = timer
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
            let lastApp = lastNotifiedApp
            let lastTitle = lastNotifiedTitle
            stop(clearState: false)
            lastNotifiedApp = lastApp
            lastNotifiedTitle = lastTitle
        }
        if let autoCoordinator, let preferences {
            let telemetry = telemetryCount
            _ = start(autoCoordinator: autoCoordinator, preferences: preferences)
            telemetryCount = telemetry
        }
    }

    private func schedulePermissionRetry(autoCoordinator: AutoRecordingCoordinator?, preferences: PreferencesService) {
        permissionRetryTask?.cancel()
        let attempt = permissionRetryAttempts + 1
        let delay = min(permissionRetryDelay * pow(2.0, Double(attempt - 1)), 300)
        permissionRetryTask = Task.detached { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.permissionRetryAttempts = attempt
                if self.axCheck() {
                    _ = self.start(autoCoordinator: autoCoordinator, preferences: preferences)
                } else {
                    self.schedulePermissionRetry(autoCoordinator: autoCoordinator, preferences: preferences)
                }
            }
        }
    }

    private func pollFrontmostApp() async {
        pollGeneration &+= 1
        let generation = pollGeneration
        if let previous = activePollTask {
            previous.cancel()
            await previous.value
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            guard generation == self.pollGeneration else { return }
            guard self.axCheck() else {
                self.permissionDenied = true
                self.stop(clearState: false)
                if let autoCoordinator, let preferences {
                    self.schedulePermissionRetry(autoCoordinator: autoCoordinator, preferences: preferences)
                }
                return
            }
            guard self.preferencesAllowNotifications else { return }
            guard let app = NSWorkspace.shared.frontmostApplication,
                  let bundleID = app.bundleIdentifier else {
                if await self.handleBackgroundDetection(excluding: nil) { return }
                guard generation == self.pollGeneration else { return }
                self.autoCoordinator?.onNoDetection()
                self.logTelemetry(result: "no-app", bundleID: nil, host: nil)
                return
            }

            guard self.supportedMeetingBundles.contains(bundleID) else {
                self.resetLastNotification()
                if await self.handleBackgroundDetection(excluding: bundleID) { return }
                guard generation == self.pollGeneration else { return }
                self.autoCoordinator?.onNoDetection()
                self.logTelemetry(result: "unsupported-bundle", bundleID: bundleID, host: nil)
                return
            }

        guard self.isMicActive else {
            if await self.handleBackgroundDetection(excluding: bundleID) { return }
            guard generation == self.pollGeneration else { return }
            self.autoCoordinator?.onNoDetection()
            self.logTelemetry(result: "mic-inactive", bundleID: bundleID, host: nil)
            return
        }

            guard let titleInfo = await self.resolveTitleInfo(for: app) else {
                if await self.handleBackgroundDetection(excluding: bundleID) { return }
                guard generation == self.pollGeneration else { return }
                self.autoCoordinator?.onNoDetection()
                self.logTelemetry(result: "no-title", bundleID: bundleID, host: nil)
                return
            }

            guard generation == self.pollGeneration else { return }
            await self.processDetection(app: app, bundleID: bundleID, titleInfo: titleInfo)
        }
        activePollTask = task
        await task.value
    }

    /// Fall back to detecting native meeting apps when they are running in the background
    /// (non-frontmost) but the microphone is active. This helps catch minimized/behind other
    /// windows sessions without relying on browser URL heuristics.
    private func handleBackgroundDetection(excluding bundleID: String?) async -> Bool {
        guard isMicActive else { return false }
        guard let preferences else { return false }

        let runningApps = await Task.detached(priority: .utility) {
            NSWorkspace.shared.runningApplications
        }.value
        if Task.isCancelled { return false }

        let candidate = runningApps.first { app in
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

    @MainActor
    private func activeWindowTitle(for app: NSRunningApplication) -> (displayTitle: String, urlDescription: String?, redacted: String?)? {
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
            logger.error("Focused window is not an AXUIElement (type=\(CFGetTypeID(window)))")
            return nil
        }
        // Safe due to CFTypeID guard above.
        let windowElement = unsafeDowncast(window as AnyObject, to: AXUIElement.self)

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
        } else {
            let now = Date()
            let lastNotice = lastMissingURLNotice ?? .distantPast
            if now.timeIntervalSince(lastNotice) > 300 {
                lastMissingURLNotice = now
                let display = app.localizedName ?? "Browser"
                NotificationHelper.sendBrowserURLMissingIfNeeded(appName: display)
            }
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
        let now = Date()
        if axQueryInFlight {
            logger.debug("AX query already in flight; throttling")
            return nil
        }
        if let last = lastAXQueryDate, now.timeIntervalSince(last) < minAXQueryInterval {
            logger.debug("AX query throttled to avoid rapid polling")
            return nil
        }
        axQueryInFlight = true
        defer {
            axQueryInFlight = false
            lastAXQueryDate = Date()
        }
        let result = await Task.detached(priority: .utility) { [weak self] () -> (displayTitle: String, urlDescription: String?, redacted: String?)? in
            guard let self else { return nil }
            return await MainActor.run { self.activeWindowTitle(for: app) }
        }.value
        if Task.isCancelled {
            return nil
        }
        return result
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
        return supportedHosts.contains { domain in
            host == domain || host.hasSuffix(".\(domain)")
        }
    }

    private var preferencesAllowNotifications: Bool {
        guard let preferences else { return false }
        return (preferences.meetingNotificationsEnabled || preferences.autoRecordingEnabled)
    }

    private func resetLastNotification() {
        lastNotifiedApp = nil
        lastNotifiedTitle = nil
    }

    private func resolveTitleInfo(for app: NSRunningApplication) async -> (displayTitle: String, urlDescription: String?, redacted: String?)? {
        await withTaskGroup(of: (displayTitle: String, urlDescription: String?, redacted: String?)?.self) { group -> (displayTitle: String, urlDescription: String?, redacted: String?)? in
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
    }

    private func processDetection(
        app: NSRunningApplication,
        bundleID: String,
        titleInfo: (displayTitle: String, urlDescription: String?, redacted: String?)
    ) async {
        // Avoid spamming notifications for the same window.
        if lastNotifiedApp == bundleID && lastNotifiedTitle == titleInfo.displayTitle {
            return
        }

        lastNotifiedApp = bundleID
        lastNotifiedTitle = titleInfo.displayTitle
        lastDetectionDate = Date()

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

    private func isBrowser(_ bundleID: String) -> Bool {
        browserBundles.contains(bundleID)
    }

    private func adjustedInterval() -> TimeInterval {
        guard let lastDetectionDate else { return pollInterval }
        let idleDuration = Date().timeIntervalSince(lastDetectionDate)
        if idleDuration > idlePollingBackoffThreshold {
            return max(pollInterval, 5.0)
        }
        return pollInterval
    }

}

private extension CallDetectionService {
    func logTelemetry(result: String, bundleID: String?, host: String?) {
        let now = Date()
        if now.timeIntervalSince(telemetryResetDate) > 3600 {
            telemetryResetDate = now
            telemetryCount = 0
        }
        guard telemetryCount < maxTelemetryPerSession else { return }
        telemetryCount += 1
        let safeHost = (host ?? "unknown").redactedForLogging()
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

private extension Int {
    func nonZeroOrDefault(_ fallback: Int) -> Int {
        return self > 0 ? self : fallback
    }
}
