import Foundation

/// Manages transcription of audio files using whisper.cpp
actor TranscriptionService {
    enum Error: LocalizedError {
        case whisperBinaryNotFound
        case modelNotFound
        case transcriptionFailed(String)
        case invalidInputPath
        
        var errorDescription: String? {
            switch self {
            case .whisperBinaryNotFound:
                return "Whisper.cpp binary not found. Please install whisper.cpp first."
            case .modelNotFound:
                return "Whisper model not found. Please download ggml-base.en.bin."
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
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
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
            throw Error.whisperBinaryNotFound
        }
        
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw Error.modelNotFound
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
        
        do {
            try process.run()
            
            return try await withCheckedThrowingContinuation { continuation in
                let queue = DispatchQueue(label: "com.overhear.transcription")
                queue.async {
                    process.waitUntilExit()
                    
                    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    let errorString = String(data: errorData, encoding: .utf8) ?? ""
                    
                    if process.terminationStatus != 0 {
                        let error = Error.transcriptionFailed(errorString.isEmpty ? "Unknown error" : errorString)
                        continuation.resume(throwing: error)
                        return
                    }
                    
                    // Read the output text file
                    let outputPath = outputPrefix + ".txt"
                    do {
                        let transcript = try String(contentsOfFile: outputPath, encoding: .utf8)
                        
                        // Clean up temp files
                        try? FileManager.default.removeItem(atPath: outputPath)
                        
                        continuation.resume(returning: transcript)
                    } catch {
                        continuation.resume(throwing: Error.transcriptionFailed("Could not read transcript: \(error.localizedDescription)"))
                    }
                }
            }
        } catch {
            throw Error.transcriptionFailed(error.localizedDescription)
        }
    }
}
