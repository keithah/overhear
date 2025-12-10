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
    private var bufferObservers: [UUID: AudioBufferObserver] = [:]

    typealias AudioBufferObserver = @Sendable (AVAudioPCMBuffer) -> Void

    func startCapture(duration: TimeInterval, outputURL: URL) async throws -> URL {
        guard !isRecording else { throw Error.alreadyRecording }
        await log("startCapture requested (duration: \(duration)s, output: \(outputURL.path))")
        let format = engine.inputNode.outputFormat(forBus: 0)
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let file = try AVAudioFile(forWriting: outputURL, settings: format.settings)

        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            do {
                try file.write(from: buffer)
                self.notifyBufferObservers(buffer: buffer)
            } catch {
                Task { @MainActor in
                    await self.log("Tap write failed: \(error.localizedDescription)")
                    await self.finalizeRecording(result: .failure(Error.captureFailed(error.localizedDescription)))
                }
            }
        }

        try engine.start()
        await log("Audio engine started")
        self.file = file
        self.outputURL = outputURL
        self.isRecording = true

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Swift.Error>) in
                self.continuation = continuation
                self.durationTask = Task { [weak self, duration, targetURL = outputURL] in
                    try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                    guard let self else { return }
                    await self.finalizeRecording(result: .success(targetURL))
                }
            }
        } onCancel: { [weak self] in
            Task { [weak self] in
                guard let self else { return }
                await self.finalizeRecording(result: .failure(Error.stoppedEarly))
            }
        }
    }

    func registerBufferObserver(_ observer: @escaping AudioBufferObserver) -> UUID {
        let id = UUID()
        bufferObservers[id] = observer
        return id
    }

    func unregisterBufferObserver(_ id: UUID) {
        bufferObservers.removeValue(forKey: id)
    }

    func stopCapture() async {
        await log("stopCapture requested")
        guard isRecording else { return }
        guard let targetURL = outputURL else {
            await log("stopCapture failed - missing output URL")
            await finalizeRecording(result: .failure(Error.captureFailed("Missing output file")))
            return
        }
        await finalizeRecording(result: .success(targetURL))
    }

    private func finalizeRecording(result: Result<URL, Swift.Error>) async {
        guard isRecording else { return }
        isRecording = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        durationTask?.cancel()
        durationTask = nil

        switch result {
        case .success(let url):
            continuation?.resume(returning: url)
            await log("Recording completed successfully: \(url.path)")
        case .failure(let error):
            continuation?.resume(throwing: error)
            await log("Recording finished with error: \(error.localizedDescription)")
        }
        continuation = nil
    }

    private func notifyBufferObservers(buffer: AVAudioPCMBuffer) {
        guard !bufferObservers.isEmpty else { return }
        for observer in bufferObservers.values {
            guard let copy = buffer.cloned() else { continue }
            observer(copy)
        }
    }

    private func log(_ message: String) async {
        logger.info("\(message, privacy: .public)")
        FileLogger.log(category: "AVAudioCaptureService", message: message)
    }

}

private extension AVAudioPCMBuffer {
    func cloned() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else {
            return nil
        }
        copy.frameLength = frameLength
        if let src = floatChannelData, let dst = copy.floatChannelData {
            let channels = Int(format.channelCount)
            let frames = Int(frameLength)
            for channel in 0..<channels {
                dst[channel].assign(from: src[channel], count: frames)
            }
        } else if let src = int16ChannelData, let dst = copy.int16ChannelData {
            let channels = Int(format.channelCount)
            let frames = Int(frameLength)
            for channel in 0..<channels {
                dst[channel].assign(from: src[channel], count: frames)
            }
        }
        return copy
    }
}

extension AVAudioPCMBuffer: @unchecked Sendable {}
