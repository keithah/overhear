import AppKit
@preconcurrency import ApplicationServices
import os.log

enum AccessibilityHelper {
    private static let logger = Logger(subsystem: "com.overhear.app", category: "AccessibilityHelper")
    private static func log(_ message: String) {
        logger.info("\(message, privacy: .public)")
        FileLogger.log(category: "Accessibility", message: message)
    }

    static func isTrusted() -> Bool {
        let trusted = AXIsProcessTrusted()
        log("AX trusted check: \(trusted)")
        return trusted
    }

    /// Triggers the system Accessibility prompt (best-effort) and returns whether the app is trusted.
    @MainActor
    static func requestPermissionPrompt() async -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options: CFDictionary = [promptKey: true] as CFDictionary
        log("Requesting Accessibility prompt for bundle \(Bundle.main.bundleIdentifier ?? "unknown") at path \(Bundle.main.bundleURL.path)")
        let alreadyTrusted = AXIsProcessTrustedWithOptions(options)
        if alreadyTrusted {
            log("AX already trusted; skipping prompt")
            return true
        }
        // Quick re-check; if already determined, return immediately.
        if AXIsProcessTrusted() {
            log("AX already trusted after prompt")
            return true
        }
        // Best-effort: poll trust status after a short delay without blocking the main actor.
        let trusted = await Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1s
            return AXIsProcessTrusted()
        }.value
        log("AX trust after prompt: \(trusted)")
        return trusted
    }

    static func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        log("Opening Accessibility settings")
        NSWorkspace.shared.open(url)
    }

    static func revealCurrentApp() {
        let bundleURL = Bundle.main.bundleURL.standardizedFileURL
        log("Revealing app in Finder at \(bundleURL.path)")
        NSWorkspace.shared.activateFileViewerSelecting([bundleURL])
    }
}
