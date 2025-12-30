import Foundation

/// Central gate to coordinate manual and auto recording so only one is active at a time.
actor RecordingStateGate {
    private var manualActive = false
    private var autoActive = false

    func beginManual() {
        manualActive = true
        autoActive = false
    }

    func endManual() {
        manualActive = false
    }

    /// Attempts to start an auto recording. Returns false if manual or auto is already active.
    func beginAuto() -> Bool {
        guard !manualActive, !autoActive else { return false }
        autoActive = true
        return true
    }

    func endAuto() {
        autoActive = false
    }

    var isManualActive: Bool {
        manualActive
    }
}
