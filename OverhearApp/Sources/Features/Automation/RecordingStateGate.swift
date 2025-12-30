import Foundation

/// Central gate to coordinate manual and auto recording so only one is active at a time.
/// Usage:
/// - Manual: call `beginManual()` before starting; if false, abort. Always call `endManual()`.
/// - Auto: call `beginAuto()` before starting; if false, abort. Always call `endAuto()`.
/// Manual is expected to stop auto before taking the gate; this actor only arbitrates state.
actor RecordingStateGate {
    private var manualActive = false
    private var autoActive = false

    /// Attempts to begin manual recording; returns false if auto is active.
    func beginManual() -> Bool {
        guard !autoActive else { return false }
        manualActive = true
        return true
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
