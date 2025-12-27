import SwiftUI
import AppKit

struct LiveTranscriptList: View {
    let segments: [LiveTranscriptSegment]
    var searchText: String = ""
    private let palette: [Color] = [
        .blue, .purple, .green, .orange, .pink, .teal, .indigo, .brown
    ]

    private func color(for speaker: String) -> Color {
        let hash = abs(speaker.hashValue)
        return palette[hash % palette.count]
    }

    private var filteredSegments: [LiveTranscriptSegment] {
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return segments
        }
        let term = searchText.lowercased()
        return segments.filter { $0.text.lowercased().contains(term) || ($0.speaker?.lowercased().contains(term) ?? false) }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if filteredSegments.isEmpty {
                        Text("Waiting for audio…")
                            .font(.system(size: 13, weight: .regular, design: .monospaced))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ForEach(filteredSegments) { segment in
                            VStack(alignment: .leading, spacing: 4) {
                                if let speaker = segment.speaker {
                                    HStack(spacing: 6) {
                                        Circle()
                                            .fill(color(for: speaker))
                                            .frame(width: 8, height: 8)
                                        Text(speaker)
                                            .font(.caption.bold())
                                            .foregroundColor(color(for: speaker))
                                    }
                                }
                                Text(segment.text)
                                    .font(.system(size: 13, weight: .regular, design: .monospaced))
                            }
                            .padding(.vertical, 6)
                            .padding(.horizontal, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(segment.isConfirmed ? Color(NSColor.controlBackgroundColor) : Color.blue.opacity(0.15))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(segment.isConfirmed ? Color.secondary.opacity(0.25) : Color.blue.opacity(0.35))
                            )
                            .id(segment.id)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
            .onChange(of: filteredSegments.count) { _, _ in
                if let last = filteredSegments.last {
                    withAnimation {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        .frame(maxHeight: 200)
        .background(Color(NSColor.textBackgroundColor))
        .cornerRadius(6)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
    }
}

@MainActor
final class LiveNotesWindowController {
    static let shared = LiveNotesWindowController()

    private var window: NSWindow?
    private var hostingController: NSHostingController<LiveNotesView>?
    private var autoWindow: NSWindow?
    private var autoHostingController: NSHostingController<LiveNotesManagerView>?

    func show(with coordinator: MeetingRecordingCoordinator) {
        if let hosting = hostingController {
            hosting.rootView = LiveNotesView(coordinator: coordinator, onHide: { [weak self] in
                self?.hide()
            })
            window?.makeKeyAndOrderFront(nil)
            return
        }

        let view = LiveNotesView(coordinator: coordinator, onHide: { [weak self] in
            self?.hide()
        })
        let controller = NSHostingController(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 420),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = "Live Notes"
        window.contentView = controller.view
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)

        self.window = window
        self.hostingController = controller
    }

    func hide() {
        window?.orderOut(nil)
    }

    func show(autoManager: MeetingRecordingManager) {
        if let controller = autoHostingController {
            controller.rootView = LiveNotesManagerView(manager: autoManager, onHide: { [weak self] in
                self?.hideAuto()
            })
            autoWindow?.makeKeyAndOrderFront(nil)
            return
        }

        let view = LiveNotesManagerView(manager: autoManager, onHide: { [weak self] in
            self?.hideAuto()
        })
        let controller = NSHostingController(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 420),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = "Live Notes"
        window.contentView = controller.view
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)

        self.autoWindow = window
        self.autoHostingController = controller
    }

    func hideAuto() {
        autoWindow?.orderOut(nil)
    }
}
