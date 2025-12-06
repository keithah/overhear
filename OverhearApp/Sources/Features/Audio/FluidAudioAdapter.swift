import Foundation
import os.log

/// Defines the behaviors expected of a FluidAudio client implementation.
protocol FluidAudioClient: Sendable {
    func transcribe(url: URL) async throws -> String
    func diarize(url: URL) async throws -> String
}

/// Abstraction for wiring FluidAudio once the framework is available.
enum FluidAudioAdapter {
    static func makeClient() -> FluidAudioClient? {
        #if canImport(FluidAudio)
        return RealFluidAudioClient()
        #else
        return nil
        #endif
    }
}

/// Client used while FluidAudio integration is pending.
private struct RealFluidAudioClient: FluidAudioClient {
    private static let logger = Logger(subsystem: "com.overhear.app", category: "FluidAudioAdapter")

    func transcribe(url: URL) async throws -> String {
        Self.logger.warning("FluidAudio placeholder transcribe called; placeholder client cannot produce transcripts.")
        throw FluidAudioAdapterError.notImplemented
    }

    func diarize(url: URL) async throws -> String {
        Self.logger.warning("FluidAudio placeholder diarize called; placeholder client cannot produce speaker analysis.")
        throw FluidAudioAdapterError.notImplemented
    }
}

/// Marks that FluidAudio wiring is still pending so callers can fall back gracefully.
private enum FluidAudioAdapterError: LocalizedError {
    case notImplemented

    var errorDescription: String? {
        "FluidAudio client is not yet implemented in this build."
    }

    var recoverySuggestion: String? {
        "Run with the legacy transcription pipeline or enable FluidAudio once the client implementation is complete."
    }
}
