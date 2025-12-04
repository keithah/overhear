import AppKit

final class HotkeyManager {
    private var monitor: Any?
    private var bindings: [HotkeyBinding] = []
    private let preferences: PreferencesService
    private let toggleAction: () -> Void
    private let joinNextAction: () -> Void

    init(preferences: PreferencesService,
         toggleAction: @escaping () -> Void,
         joinNextAction: @escaping () -> Void) {
        self.preferences = preferences
        self.toggleAction = toggleAction
        self.joinNextAction = joinNextAction

        // Initial registration
        registerHotkeys()

        // Observe preference changes to re-register
        preferences.$menubarToggleHotkey
            .merge(with: preferences.$joinNextMeetingHotkey)
            .sink { [weak self] _ in
                self?.registerHotkeys()
            }
            .store(in: &cancellables)
    }

    private var cancellables: Set<AnyCancellable> = []

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    private func registerHotkeys() {
        // Tear down existing monitor
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }

        var newBindings: [HotkeyBinding] = []
        if let toggle = HotkeyBinding(string: preferences.menubarToggleHotkey, action: toggleAction) {
            newBindings.append(toggle)
        }
        if let join = HotkeyBinding(string: preferences.joinNextMeetingHotkey, action: joinNextAction) {
            newBindings.append(join)
        }
        bindings = newBindings

        guard !bindings.isEmpty else { return }

        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return }
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            let key = event.charactersIgnoringModifiers?.lowercased()
            for binding in self.bindings {
                if binding.matches(flags: flags, key: key) {
                    binding.action()
                    break
                }
            }
        }
    }
}

private struct HotkeyBinding {
    let modifiers: NSEvent.ModifierFlags
    let key: String
    let action: () -> Void

    init?(string: String, action: @escaping () -> Void) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var mods: NSEvent.ModifierFlags = []
        var keyChar: Character?
        for ch in trimmed {
            switch ch {
            case "^", "⌃": mods.insert(.control)
            case "⌥", "⎇": mods.insert(.option)
            case "⌘", "": mods.insert(.command)
            case "⇧", "⇪": mods.insert(.shift)
            default:
                if keyChar == nil, ch.isLetter || ch.isNumber {
                    keyChar = Character(String(ch).lowercased())
                }
            }
        }
        guard let keyChar else { return nil }
        self.modifiers = mods
        self.key = String(keyChar)
        self.action = action
    }

    func matches(flags: NSEvent.ModifierFlags, key otherKey: String?) -> Bool {
        guard let otherKey else { return false }
        return otherKey == key && flags == modifiers
    }
}
