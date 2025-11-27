import AppKit
import SwiftUI

final class MenuBarController: NSObject, NSMenuDelegate {
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
        
        guard let button = item.button else {
            return
        }
        
        button.title = "📅"
        
        // Create menu
        let menu = NSMenu()
        menu.delegate = self
        
        // Create menu item with proper target/action
        let menuItem = NSMenuItem(title: "Show Meetings", action: #selector(togglePopoverAction), keyEquivalent: "")
        menuItem.target = self
        menu.addItem(menuItem)
        
        // Attach menu to status item
        item.menu = menu
        
        // Setup popover
        popover.behavior = .semitransient
        popover.contentSize = NSSize(width: 380, height: 520)
        popover.contentViewController = NSHostingController(rootView: MenuBarContentView(viewModel: viewModel, preferences: preferences) {
            self.preferencesWindowController.show()
        })
        
        // Store status item (must be retained)
        statusItem = item
    }
    
    @objc
    func togglePopoverAction() {
        guard let button = statusItem?.button else {
            return
        }
        
        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        }
    }
}
