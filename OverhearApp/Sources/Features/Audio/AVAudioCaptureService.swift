import AVFoundation
import Foundation
import os.log

/// Captures microphone audio locally using AVAudioEngine.
actor AVAudioCaptureService {
    private let logger = Logger(subsystem: "com.overhear.app", category: "AVAudioCaptureService")
    private var isLoggingEnabled: Bool {
        if ProcessInfo.processInfo.environment["OVERHEAR_FILE_LOGS"] == "1" {
            return true
        }
        return UserDefaults.standard.bool(forKey: "overhear.enableFileLogs")
    }

    enum Error: LocalizedError {
        case alreadyRecording
        case captureFailed(String)
        case stoppedEarly

        var errorDescription: String? {
            switch self {
            case .alreadyRecording:
                return "Audio capture already in progress"
            case .captureFailed(let message):
                return "Audio capture failed: \(message)"
            case .stoppedEarly:
                return "Audio capture stopped before duration completed"
            }
        }
    }

    private let engine = AVAudioEngine()
    private var file: AVAudioFile?
    private var outputURL: URL?
    private var continuation: CheckedContinuation<URL, Swift.Error>?
    private var isRecording = false
    private var durationTask: Task<Void, Never>?

    func startCapture(duration: TimeInterval, outputURL: URL) async throws -> URL {
        guard !isRecording else { throw Error.alreadyRecording }
        log("startCapture requested (duration: \(duration)s, output: \(outputURL.path))")
        let format = engine.inputNode.outputFormat(forBus: 0)
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let file = try AVAudioFile(forWriting: outputURL, settings: format.settings)

        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            do {
                try file.write(from: buffer)
            } catch {
                self.log("Tap write failed: \(error.localizedDescription)")
                Task {
                    await self.finishRecording(error: Error.captureFailed(error.localizedDescription))
                }
            }
        }

        try engine.start()
        log("Audio engine started")
        self.file = file
        self.outputURL = outputURL
        self.isRecording = true

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Swift.Error>) in
                self.continuation = continuation
                self.durationTask = Task { [duration] in
                    try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                    await self.finishRecording(success: true)
                }
            }
        } onCancel: {
            Task {
                await self.finishRecording(error: Error.stoppedEarly)
            }
        }
    }

    func stopCapture() async {
        log("stopCapture requested")
        await finishRecording(error: Error.stoppedEarly)
    }

    private func finishRecording(success: Bool = false) async {
        guard isRecording else { return }
        isRecording = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        durationTask?.cancel()
        durationTask = nil

        if success, let url = outputURL {
            continuation?.resume(returning: url)
            log("Recording completed successfully: \(url.path)")
        } else {
            continuation?.resume(throwing: Error.stoppedEarly)
            log("Recording finished without success")
        }
        continuation = nil
    }

    private func finishRecording(error: Swift.Error) async {
        guard isRecording else { return }
        isRecording = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        durationTask?.cancel()
        durationTask = nil

        continuation?.resume(throwing: error)
        log("Recording finished with error: \(error.localizedDescription)")
        continuation = nil
    }

    private func log(_ message: String) {
        logger.info("\(message, privacy: .public)")
        guard isLoggingEnabled else { return }
        let line = "[AVAudioCaptureService] \(Date()): \(message)\n"
        appendLogLine(line)
    }

    private func appendLogLine(_ line: String) {
        let url = URL(fileURLWithPath: "/tmp/overhear.log")
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }
}
