import Foundation
import os.log

/// Defines the behaviors expected of a FluidAudio client implementation.
protocol FluidAudioClient: Sendable {
    func transcribe(url: URL) async throws -> String
    func diarize(url: URL) async throws -> [SpeakerSegment]
}

/// Abstraction for wiring FluidAudio once the framework is available.
enum FluidAudioAdapter {
    static func makeClient() -> FluidAudioClient? {
        #if canImport(FluidAudio)
        return RealFluidAudioClient(configuration: FluidAudioConfiguration.fromEnvironment())
        #else
        return nil
        #endif
    }
}

/// Marks that FluidAudio wiring is still pending so callers can fall back gracefully.
private enum FluidAudioAdapterError: LocalizedError {
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

extension AsrManager: @unchecked Sendable {}

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
        let manager = try await ensureAsrManager()
        return try await manager.transcribe(audioURL, source: .system)
    }

    func diarize(audioURL: URL) async throws -> DiarizationResult {
        let diarizer = try await ensureDiarizerManager()
        let samples = try converter.resampleAudioFile(audioURL)
        return try diarizer.performCompleteDiarization(samples)
    }

    // MARK: - Initialization Helpers

    private func ensureAsrManager() async throws -> AsrManager {
        if let manager = asrManager {
            return manager
        }

        return try await withCheckedThrowingContinuation { continuation in
            asrContinuations.append(continuation)
            guard !isAsrInitializing else { return }
            isAsrInitializing = true
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
            return manager
        }

        return try await withCheckedThrowingContinuation { continuation in
            diarizerContinuations.append(continuation)
            guard !isDiarizerInitializing else { return }
            isDiarizerInitializing = true
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
        try await manager.initialize(models: models)
        Self.logger.info("FluidAudio ASR initialized version \(self.configuration.asrModelVersion)")
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
        let directory = configuration.asrModelsDirectory
            ?? AsrModels.defaultCacheDirectory(for: configuration.asrModelVersion)
        try ensureDirectory(directory)
        if AsrModels.modelsExist(at: directory, version: configuration.asrModelVersion) {
            return try await AsrModels.load(from: directory, version: configuration.asrModelVersion)
        }
        return try await AsrModels.downloadAndLoad(to: directory, version: configuration.asrModelVersion)
    }

    private func loadDiarizerModels() async throws -> DiarizerModels {
        let directory = configuration.diarizerModelsDirectory ?? DiarizerModels.defaultModelsDirectory()
        try ensureDirectory(directory)
        return try await DiarizerModels.download(to: directory)
    }

    private func ensureDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}

private struct RealFluidAudioClient: FluidAudioClient {
    private let store: FluidAudioModelStore
    private static let logger = Logger(subsystem: "com.overhear.app", category: "FluidAudioAdapter")

    init(configuration: FluidAudioConfiguration) {
        self.store = FluidAudioModelStore(configuration: configuration)
    }

    func transcribe(url: URL) async throws -> String {
        let result = try await store.transcribe(audioURL: url)
        Self.logger.info("FluidAudio recognized \(result.text.count) characters (confidence: \(result.confidence))")
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func diarize(url: URL) async throws -> [SpeakerSegment] {
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
    }
}
#endif
