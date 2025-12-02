import Foundation

/// Manages audio capture for meetings using the AudioSpike CLI tool
actor AudioCaptureService {
    enum Error: LocalizedError {
        case audioSpikeNotFound(String)
        case captureFailed(String)
        case invalidOutputPath
        
        var errorDescription: String? {
            switch self {
            case .audioSpikeNotFound(let path):
                return "AudioSpike tool not found at \(path). Please build and install it to ~/.overhear/bin/AudioSpike."
            case .captureFailed(let message):
                return "Audio capture failed: \(message)"
            case .invalidOutputPath:
                return "Invalid output path for audio capture"
            }
        }
    }
    
    private let audioSpikeExecutablePath: String
    private var currentProcess: Process?
    private var isCapturing = false
    
    init(audioSpikeExecutablePath: String? = nil) {
        // Default path for AudioSpike executable
        if let provided = audioSpikeExecutablePath {
            self.audioSpikeExecutablePath = provided
        } else {
            let defaultPath = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".overhear/bin/AudioSpike")
                .path
            self.audioSpikeExecutablePath = defaultPath
        }
    }
    
    /// Start capturing audio for the specified duration
    /// - Parameters:
    ///   - duration: Duration in seconds
    ///   - outputURL: Where to save the WAV file
    /// - Returns: URL of the saved WAV file
    func startCapture(duration: TimeInterval, outputURL: URL) async throws -> URL {
        guard !isCapturing else {
            throw Error.captureFailed("Capture already in progress")
        }
        
        isCapturing = true
        defer { isCapturing = false }
        
        // Verify AudioSpike exists
        guard FileManager.default.fileExists(atPath: audioSpikeExecutablePath) else {
            throw Error.audioSpikeNotFound(audioSpikeExecutablePath)
        }
        
        // Create output directory if needed
        let outputDirectory = outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        
        return try await captureAudio(duration: duration, outputURL: outputURL)
    }
    
    /// Stop any ongoing capture
    func stopCapture() {
        guard let process = currentProcess, process.isRunning else { return }
        process.terminate()
        currentProcess = nil
    }
    
    // MARK: - Private
    
    private func captureAudio(duration: TimeInterval, outputURL: URL) async throws -> URL {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: audioSpikeExecutablePath)
        process.arguments = [
            "--duration", String(Int(duration)),
            "--output", outputURL.path
        ]
        
        let pipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = pipe
        process.standardError = errorPipe
        
        self.currentProcess = process
        
        return try await withTaskCancellationHandler {
            do {
                try process.run()
                
                // Wait for process completion using async approach
                return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Swift.Error>) in
                    // Use DispatchQueue only for blocking I/O, not for concurrency control
                    let queue = DispatchQueue(label: "com.overhear.audio.capture", qos: .userInitiated)
                    queue.async {
                        process.waitUntilExit()
                        
                        // Read error output and determine result
                        let errorString = Self.readErrorOutput(from: errorPipe)
                        
                        if process.terminationStatus != 0 {
                            let error = Error.captureFailed(errorString.isEmpty ? "Unknown error" : errorString)
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume(returning: outputURL)
                        }
                    }
                }
            } catch {
                throw Error.captureFailed(error.localizedDescription)
            }
        } onCancel: {
            process.terminate()
        }
    }
    
    /// Helper method to safely read error pipe output
    private static func readErrorOutput(from errorPipe: Pipe) -> String {
        do {
            let errorData = try errorPipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: errorData, encoding: .utf8) ?? ""
        } catch {
            return "Failed to read error output: \(error.localizedDescription)"
        }
    }
}
