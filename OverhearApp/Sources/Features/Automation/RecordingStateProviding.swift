import Foundation

@MainActor
protocol RecordingStateProviding: AnyObject {
    var isRecording: Bool { get }
}
