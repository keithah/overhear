import Foundation

/// Minimal interface for checking whether a recording session is in progress.
@MainActor
protocol RecordingStateProviding: AnyObject {
    var isRecording: Bool { get }
}
