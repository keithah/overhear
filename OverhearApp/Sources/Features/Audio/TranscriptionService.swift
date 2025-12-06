import Foundation
import os.log

// MARK: - Transcription Engines

protocol TranscriptionEngine: Sendable {
    func transcribe(audioURL: URL) async throws -> String
}

protocol DiarizationEngine: Sendable {
    func diarize(audioURL: URL) async throws -> String
}

enum TranscriptionEngineFactory {
    static func makeEngine() -> TranscriptionEngine {
        // Feature flag for future FluidAudio integration
        let useFluid = ProcessInfo.processInfo.environment["OVERHEAR_USE_FLUIDAUDIO"] == "1"
        if useFluid, let fluid = FluidAudioAdapter.makeClient() {
            return FluidAudioTranscriptionEngine(fluid: fluid, fallback: TranscriptionService())
        }
        return TranscriptionService()
    }
}

/// Placeholder for FluidAudio-backed transcription. Currently falls back with a clear error
/// so we can wire FluidAudio later without changing call sites.
struct FluidAudioTranscriptionEngine: TranscriptionEngine {
    enum FluidError: LocalizedError {
        case notAvailable
        var errorDescription: String? {
            "FluidAudio transcription not yet available in this build."
        }
        var recoverySuggestion: String? {
            "Falling back to the built-in Whisper transcription engine."
        }
    }
    
    private let fluid: FluidAudioClient?
    private let fallback: TranscriptionEngine
    private let logger = Logger(subsystem: "com.overhear.app", category: "Transcription")
    
    init(fluid: FluidAudioClient?, fallback: TranscriptionEngine) {
        self.fluid = fluid
        self.fallback = fallback
    }
    
    func transcribe(audioURL: URL) async throws -> String {
        guard let fluid else {
            logger.info("FluidAudio not available; falling back to Whisper transcription.")
            return try await fallback.transcribe(audioURL: audioURL)
        }

        do {
            logger.debug("FluidAudio available; attempting Fluid transcription.")
            let transcript = try await fluid.transcribe(url: audioURL)
            if transcript.isEmpty {
                logger.warning("FluidAudio returned empty transcript; falling back to Whisper transcription.")
                return try await fallback.transcribe(audioURL: audioURL)
            }
            return transcript
        } catch {
            logger.warning("FluidAudio transcription failed (\(error.localizedDescription)); falling back to Whisper transcription.")
            return try await fallback.transcribe(audioURL: audioURL)
        }
    }
}

/// Manages transcription of audio files using whisper.cpp
actor TranscriptionService: TranscriptionEngine {
    enum Error: LocalizedError {
        case whisperBinaryNotFound(String)
        case modelNotFound(String)
        case transcriptionFailed(String)
        case invalidInputPath
        
        var errorDescription: String? {
            switch self {
            case .whisperBinaryNotFound(let path):
                return "Whisper.cpp binary not found at \(path). Install whisper.cpp or set the WHISPER_BIN environment variable."
            case .modelNotFound(let path):
                return "Whisper model not found at \(path). Download ggml-base.en.bin from the whisper.cpp repository."
            case .transcriptionFailed(let message):
                return "Transcription failed: \(message)"
            case .invalidInputPath:
                return "Invalid audio file path"
            }
        }
    }
    
    private let whisperBinaryPath: String
    private let modelPath: String
    
    init(whisperBinaryPath: String? = nil, modelPath: String? = nil) {
        // Default paths - use application support directory for better resource management
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first 
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        let whisperDir = appSupport.appendingPathComponent("com.overhear.app/whisper")
        
        // Try environment variables first, then use app bundle resources, then fallback to standard locations
        if let customBinaryPath = whisperBinaryPath ?? ProcessInfo.processInfo.environment["WHISPER_BIN"] {
            self.whisperBinaryPath = customBinaryPath
        } else if let bundleBinary = Bundle.main.path(forResource: "main", ofType: nil) {
            self.whisperBinaryPath = bundleBinary
        } else {
            self.whisperBinaryPath = "/usr/local/bin/main"
        }
        
        if let customModelPath = modelPath ?? ProcessInfo.processInfo.environment["WHISPER_MODEL"] {
            self.modelPath = customModelPath
        } else if let bundleModel = Bundle.main.path(forResource: "ggml-base.en", ofType: "bin") {
            self.modelPath = bundleModel
        } else {
            self.modelPath = whisperDir.appendingPathComponent("ggml-base.en.bin").path
        }
    }
    
    /// Transcribe an audio file
    /// - Parameter audioURL: Path to the audio WAV file
    /// - Returns: Transcribed text
    func transcribe(audioURL: URL) async throws -> String {
        // Verify files exist
        guard FileManager.default.fileExists(atPath: whisperBinaryPath) else {
            throw Error.whisperBinaryNotFound(whisperBinaryPath)
        }
        
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw Error.modelNotFound(modelPath)
        }
        
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw Error.invalidInputPath
        }
        
        return try await runWhisper(audioURL: audioURL)
    }
    
    // MARK: - Private
    
    private func runWhisper(audioURL: URL) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: whisperBinaryPath)
        
        // Output file will be in temp directory with .txt extension
        let tempDir = FileManager.default.temporaryDirectory
        let outputPrefix = tempDir.appendingPathComponent(UUID().uuidString).path
        
        process.arguments = [
            "-m", modelPath,
            "-f", audioURL.path,
            "-otxt",
            "-of", outputPrefix
        ]
        
        let pipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = pipe
        process.standardError = errorPipe
        
        return try await withTaskCancellationHandler {
            do {
                try process.run()
                
                // Wait for process completion using proper async pattern
                return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Swift.Error>) in
                    let queue = DispatchQueue(label: "com.overhear.transcription", qos: .userInitiated)
                    queue.async {
                        // Clean up temp file when done (success or failure)
                        defer {
                            let outputPath = outputPrefix + ".txt"
                            try? FileManager.default.removeItem(atPath: outputPath)
                        }
                        
                        // Wait for process to complete
                        process.waitUntilExit()
                        
                        // Handle completion
                        self.handleWhisperCompletion(
                            process: process,
                            errorPipe: errorPipe,
                            outputPrefix: outputPrefix,
                            continuation: continuation
                        )
                    }
                }
            } catch {
                throw Error.transcriptionFailed(error.localizedDescription)
            }
        } onCancel: {
            process.terminate()
        }
    }
    
    /// Helper method to handle whisper process completion
    nonisolated private func handleWhisperCompletion(
        process: Process,
        errorPipe: Pipe,
        outputPrefix: String,
        continuation: CheckedContinuation<String, Swift.Error>
    ) {
        // Read error output
        let errorString = Self.readErrorOutput(from: errorPipe)
        
        if process.terminationStatus != 0 {
            let error = Error.transcriptionFailed(errorString.isEmpty ? "Unknown error" : errorString)
            continuation.resume(throwing: error)
            return
        }
        
        // Read the output text file
        let outputPath = outputPrefix + ".txt"
        do {
            let transcript = try String(contentsOfFile: outputPath, encoding: .utf8)
            continuation.resume(returning: transcript)
        } catch {
            continuation.resume(throwing: Error.transcriptionFailed("Could not read transcript: \(error.localizedDescription)"))
        }
    }
    
    /// Helper method to safely read error pipe output
    private static func readErrorOutput(from errorPipe: Pipe) -> String {
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: errorData, encoding: .utf8) ?? ""
    }
}
