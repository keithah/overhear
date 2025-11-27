import AppKit
import SwiftUI

final class MenuBarController: NSObject {
    private var statusItem: NSStatusItem?
    private var popover = NSPopover()
    private let viewModel: MeetingListViewModel
    private let preferencesWindowController: PreferencesWindowController
    private let preferences: PreferencesService

    init(viewModel: MeetingListViewModel, preferencesWindowController: PreferencesWindowController, preferences: PreferencesService) {
        self.viewModel = viewModel
        self.preferencesWindowController = preferencesWindowController
        self.preferences = preferences
        super.init()
    }

    func setup() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Overhear")
        item.button?.target = self
        item.button?.action = #selector(togglePopover(_:))
        item.button?.appearsDisabled = false
        statusItem = item

        popover.behavior = .transient
        popover.contentSize = NSSize(width: 380, height: 520)
        popover.contentViewController = NSHostingController(rootView: MenuBarContentView(viewModel: viewModel, preferences: preferences) {
            self.preferencesWindowController.show()
        })
    }

    @objc
    private func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
