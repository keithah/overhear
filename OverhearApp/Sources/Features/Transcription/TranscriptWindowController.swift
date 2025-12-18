import AppKit
import SwiftUI

/// Presents a transcript in a detached floating panel so the menu bar popover stays responsive.
final class TranscriptWindowController {
    static let shared = TranscriptWindowController()

    private var window: NSWindow?

    private func estimatedSize(for transcript: StoredTranscript) -> NSSize {
        // Width bounds
        let minWidth: CGFloat = 420
        let maxWidth: CGFloat = 680

        // Start from a comfortable default
        var targetWidth: CGFloat = 520

        // Estimate text height for the transcript body
        let body = transcript.transcript as NSString
        let bodyFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let horizontalPadding: CGFloat = 32 // ScrollView/content padding
        let boundingWidth = max(minWidth, min(maxWidth, targetWidth)) - horizontalPadding

        let textRect = body.boundingRect(
            with: NSSize(width: boundingWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: bodyFont]
        )
        let textHeight = ceil(textRect.height)

        // Estimate heights for header/footer and padding
        let headerHeight: CGFloat = 72   // title + date + padding
        let footerHeight: CGFloat = 56   // buttons row + padding
        let verticalPadding: CGFloat = 28 // content padding inside ScrollView

        var targetHeight = headerHeight + verticalPadding + textHeight + footerHeight

        // Clamp to sensible bounds
        targetWidth = max(minWidth, min(maxWidth, boundingWidth + horizontalPadding))
        targetHeight = max(360, min(720, targetHeight))

        return NSSize(width: targetWidth, height: targetHeight)
    }

    func show(transcript: StoredTranscript) {
        // Close any existing window before showing a new one
        FileLogger.log(category: "TranscriptWindow", message: "Opening transcript window for \(transcript.id) title=\(transcript.title)")
        window?.close()

        let initialSize = estimatedSize(for: transcript)
        let contentView = TranscriptDetailView(transcript: transcript)
        let hosting = NSHostingController(rootView: contentView)
        hosting.view.frame = NSRect(origin: .zero, size: initialSize)
        let panelFrame = NSRect(origin: .zero, size: initialSize)
        let panel = NSPanel(
            contentRect: panelFrame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.transient, .ignoresCycle]
        panel.becomesKeyOnlyIfNeeded = true
        panel.title = transcript.title
        panel.contentViewController = hosting
        panel.isReleasedWhenClosed = false
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.minSize = NSSize(width: 420, height: 320)
        panel.maxSize = NSSize(width: 680, height: 900)
        panel.setFrame(panelFrame, display: true)
        panel.setContentSize(initialSize)
        panel.center()

        window = panel
        panel.orderFrontRegardless()
        FileLogger.log(category: "TranscriptWindow", message: "Panel ordered front for \(transcript.id)")
        NSApp.activate(ignoringOtherApps: true)
        FileLogger.log(category: "TranscriptWindow", message: "NSApp.activate called for \(transcript.id)")
    }
}
