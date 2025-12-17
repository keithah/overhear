import Foundation
import os.log

/// Defines the behaviors expected of a FluidAudio client implementation.
protocol FluidAudioClient: Sendable {
    func transcribe(url: URL) async throws -> String
    func diarize(url: URL) async throws -> [SpeakerSegment]
}

/// Abstraction for wiring FluidAudio once the framework is available.
enum FluidAudioAdapter {
    private static let logger = Logger(subsystem: "com.overhear.app", category: "FluidAudioAdapter")

    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["OVERHEAR_USE_FLUIDAUDIO"] != "0"
    }

    static var isAvailable: Bool {
        #if canImport(FluidAudio)
        return true
        #else
        return false
        #endif
    }

    static func makeClient() -> FluidAudioClient? {
        guard isEnabled else {
            log("FluidAudio disabled via OVERHEAR_USE_FLUIDAUDIO=0")
            return nil
        }

        #if canImport(FluidAudio)
        log("FluidAudio client available; initializing")
        return RealFluidAudioClient(configuration: FluidAudioConfiguration.fromEnvironment())
        #else
        log("FluidAudio module unavailable at compile time")
        return nil
        #endif
    }

    private static func log(_ message: String) {
        logger.info("\(message, privacy: .public)")
        FileLogger.log(category: "FluidAudioAdapter", message: message)
    }
}

/// Marks that FluidAudio wiring is still pending so callers can fall back gracefully.
enum FluidAudioAdapterError: LocalizedError {
    case notImplemented
    case initializationFailed(String)
    case diarizationFailed(String)

    var errorDescription: String? {
        switch self {
        case .notImplemented:
            return "FluidAudio client is not yet implemented in this build."
        case .initializationFailed(let message):
            return "FluidAudio initialization failed: \(message)"
        case .diarizationFailed(let message):
            return "FluidAudio diarization failed: \(message)"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .notImplemented:
            return "Run with the legacy transcription pipeline or enable FluidAudio once the client implementation is complete."
        case .initializationFailed, .diarizationFailed:
            return "Verify your FluidAudio models are downloaded and accessible, or run with the Whisper fallback."
        }
    }
}

#if canImport(FluidAudio)
import FluidAudio

/// FluidAudio's ASR manager is safe to share across concurrency domains (per FluidAudio documentation).
extension AsrManager: @unchecked Sendable {}

/// FluidAudio's diarizer manager is only used via the actor and exposes thread-safe APIs.
extension DiarizerManager: @unchecked Sendable {}

struct FluidAudioConfiguration {
    let asrModelVersion: AsrModelVersion
    let asrModelsDirectory: URL?
    let diarizerModelsDirectory: URL?

    static func fromEnvironment() -> FluidAudioConfiguration {
        FluidAudioConfiguration(
            asrModelVersion: parseVersion(),
            asrModelsDirectory: url(from: "OVERHEAR_FLUIDAUDIO_ASR_MODELS"),
            diarizerModelsDirectory: url(from: "OVERHEAR_FLUIDAUDIO_DIARIZER_MODELS")
        )
    }

    var effectiveAsrDirectory: URL {
        asrModelsDirectory ?? Self.defaultAsrDirectory(for: asrModelVersion)
    }

    var effectiveDiarizerDirectory: URL {
        diarizerModelsDirectory ?? Self.defaultDiarizerDirectory()
    }

    private static func parseVersion() -> AsrModelVersion {
        switch ProcessInfo.processInfo.environment["OVERHEAR_FLUIDAUDIO_ASR_VERSION"]?.lowercased() {
        case "v2": return .v2
        default: return .v3
        }
    }

    private static func url(from env: String) -> URL? {
        guard let value = ProcessInfo.processInfo.environment[env], !value.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: value, isDirectory: true)
    }

    private static func defaultAsrDirectory(for version: AsrModelVersion) -> URL {
        defaultFluidAudioBase()
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("ASR-\(version)", isDirectory: true)
    }

    private static func defaultDiarizerDirectory() -> URL {
        defaultFluidAudioBase()
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("Diarizer", isDirectory: true)
    }

    private static func defaultFluidAudioBase() -> URL {
        let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return supportDir
            .appendingPathComponent("Overhear", isDirectory: true)
            .appendingPathComponent("FluidAudio", isDirectory: true)
    }
}

private final actor FluidAudioModelStore {
    private static let logger = Logger(subsystem: "com.overhear.app", category: "FluidAudioModelStore")

    private let configuration: FluidAudioConfiguration
    private let converter = AudioConverter()

    private var asrManager: AsrManager?
    private var diarizerManager: DiarizerManager?
    private var asrContinuations: [CheckedContinuation<AsrManager, Error>] = []
    private var diarizerContinuations: [CheckedContinuation<DiarizerManager, Error>] = []
    private var isAsrInitializing = false
    private var isDiarizerInitializing = false

    init(configuration: FluidAudioConfiguration) {
        self.configuration = configuration
    }

    func transcribe(audioURL: URL) async throws -> ASRResult {
        let start = Date()
        log("Transcription requested for \(audioURL.lastPathComponent)")
        let manager = try await ensureAsrManager()
        log("ASR manager ready; resampling and invoking FluidAudio transcription")
        do {
            // Normalize to FluidAudio-friendly PCM samples to avoid format errors
            let samples = try await Task { try converter.resampleAudioFile(audioURL) }.value
            let result = try await manager.transcribe(samples, source: .system)
            let elapsed = Date().timeIntervalSince(start)
            log("Transcription completed (\(result.text.count) chars) in \(String(format: "%.2fs", elapsed))")
            return result
        } catch {
            let elapsed = Date().timeIntervalSince(start)
            log("Transcription failed after \(String(format: "%.2fs", elapsed)): \(error.localizedDescription)")
            throw error
        }
    }

    func diarize(audioURL: URL) async throws -> DiarizationResult {
        let start = Date()
        log("Diarization requested for \(audioURL.lastPathComponent)")
        let diarizer = try await ensureDiarizerManager()
        let samples = try await Task { try converter.resampleAudioFile(audioURL) }.value
        do {
            let result = try diarizer.performCompleteDiarization(samples)
            let elapsed = Date().timeIntervalSince(start)
            log("Diarization produced \(result.segments.count) segments in \(String(format: "%.2fs", elapsed))")
            return result
        } catch {
            let elapsed = Date().timeIntervalSince(start)
            log("Diarization failed after \(String(format: "%.2fs", elapsed)): \(error.localizedDescription)")
            throw error
        }
    }

    private func log(_ message: String) {
        Self.logger.info("\(message, privacy: .public)")
        FileLogger.log(category: "FluidAudioModelStore", message: message)
    }

    // MARK: - Initialization Helpers

    private func ensureAsrManager() async throws -> AsrManager {
        if let manager = asrManager {
            log("ASR manager reuse; already initialized")
            return manager
        }

        return try await withCheckedThrowingContinuation { continuation in
            asrContinuations.append(continuation)
            guard !isAsrInitializing else { return }
            isAsrInitializing = true
            log("ASR manager initialization started")
            Task {
                do {
                    let manager = try await buildAsrManager()
                    await self.completeAsrInitialization(.success(manager))
                } catch {
                    await self.completeAsrInitialization(.failure(error))
                }
            }
        }
    }

    private func ensureDiarizerManager() async throws -> DiarizerManager {
        if let manager = diarizerManager {
            log("Diarizer manager reuse; already initialized")
            return manager
        }

        return try await withCheckedThrowingContinuation { continuation in
            diarizerContinuations.append(continuation)
            guard !isDiarizerInitializing else { return }
            isDiarizerInitializing = true
            log("Diarizer manager initialization started")
            Task {
                do {
                    let manager = try await buildDiarizerManager()
                    await self.completeDiarizerInitialization(.success(manager))
                } catch {
                    await self.completeDiarizerInitialization(.failure(error))
                }
            }
        }
    }

    private func buildAsrManager() async throws -> AsrManager {
        let models = try await loadAsrModels()
        let manager = AsrManager()
        log("Initializing FluidAudio ASR manager")
        try await manager.initialize(models: models)
        let versionDescription = String(describing: self.configuration.asrModelVersion)
        Self.logger.info("FluidAudio ASR initialized version \(versionDescription)")
        FileLogger.log(category: "FluidAudioModelStore", message: "ASR manager initialized (version \(versionDescription))")
        return manager
    }

    private func buildDiarizerManager() async throws -> DiarizerManager {
        let models = try await loadDiarizerModels()
        let manager = DiarizerManager()
        manager.initialize(models: models)
        Self.logger.info("FluidAudio diarizer initialized")
        return manager
    }

    private func completeAsrInitialization(_ result: Result<AsrManager, Error>) async {
        isAsrInitializing = false
        if case .success(let manager) = result {
            asrManager = manager
        }
        let continuations = asrContinuations
        asrContinuations = []
        for continuation in continuations {
            continuation.resume(with: result)
        }
    }

    private func completeDiarizerInitialization(_ result: Result<DiarizerManager, Error>) async {
        isDiarizerInitializing = false
        if case .success(let manager) = result {
            diarizerManager = manager
        }
        let continuations = diarizerContinuations
        diarizerContinuations = []
        for continuation in continuations {
            continuation.resume(with: result)
        }
    }

    private func loadAsrModels() async throws -> AsrModels {
        let directory = configuration.effectiveAsrDirectory
        try ensureDirectory(directory)
        log("ASR directory \(directory.path), version \(configuration.asrModelVersion)")
        if AsrModels.modelsExist(at: directory, version: configuration.asrModelVersion) {
            log("ASR models already cached")
            return try await AsrModels.load(from: directory, version: configuration.asrModelVersion)
        }
        log("Downloading ASR models to \(directory.path)")
        return try await AsrModels.downloadAndLoad(to: directory, version: configuration.asrModelVersion)
    }

    private func loadDiarizerModels() async throws -> DiarizerModels {
        let directory = configuration.effectiveDiarizerDirectory
        try ensureDirectory(directory)
        log("Downloading Diarizer models to \(directory.path)")
        return try await DiarizerModels.download(to: directory)
    }

    private func ensureDirectory(_ directory: URL) throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            log("Ensured directory \(directory.path)")
        } catch {
            throw FluidAudioAdapterError.initializationFailed("Could not create models directory at \(directory.path): \(error.localizedDescription)")
        }
    }
}

private struct RealFluidAudioClient: FluidAudioClient {
    private let store: FluidAudioModelStore
    private static let logger = Logger(subsystem: "com.overhear.app", category: "FluidAudioAdapter")

    init(configuration: FluidAudioConfiguration) {
        self.store = FluidAudioModelStore(configuration: configuration)
    }

    func transcribe(url: URL) async throws -> String {
        do {
            let result = try await store.transcribe(audioURL: url)
            Self.logger.info("FluidAudio recognized \(result.text.count) characters (confidence: \(result.confidence))")
            return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch let adapterError as FluidAudioAdapterError {
            throw adapterError
        } catch {
            throw FluidAudioAdapterError.initializationFailed(error.localizedDescription)
        }
    }

    func diarize(url: URL) async throws -> [SpeakerSegment] {
        do {
            let result = try await store.diarize(audioURL: url)
            let segments = result.segments.map { segment in
                SpeakerSegment(
                    speaker: segment.speakerId,
                    start: TimeInterval(segment.startTimeSeconds),
                    end: TimeInterval(segment.endTimeSeconds)
                )
            }
            Self.logger.info("FluidAudio diarization produced \(segments.count) segments")
            return segments
        } catch let adapterError as FluidAudioAdapterError {
            throw adapterError
        } catch {
            throw FluidAudioAdapterError.diarizationFailed(error.localizedDescription)
        }
    }
}
#endif
