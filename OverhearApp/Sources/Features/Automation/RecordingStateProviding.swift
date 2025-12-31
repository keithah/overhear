import Foundation

/// Minimal interface for checking whether a recording session is in progress.
/// Kept as a protocol so AutoRecordingCoordinator can depend on the abstraction without
/// owning MeetingRecordingCoordinator directly, making tests/mocks lightweight. MainActor
/// is used because recording state changes are published from the UI pipeline.
@MainActor
protocol RecordingStateProviding: AnyObject {
    var isRecording: Bool { get }
}
