import Foundation

/// Adapter for FluidAudio engines. At build time we conditionally use a FluidAudio client if available.
/// This keeps the API surface ready for the real dependency without breaking builds when FluidAudio
/// is not linked yet.
protocol FluidAudioClient {
    func transcribe(url: URL) async throws -> String
    func diarize(url: URL) async throws -> String
}

enum FluidAudioAdapter {
    /// Returns a FluidAudio client if the dependency is linked; otherwise nil.
    static func makeClient() -> FluidAudioClient? {
        #if canImport(FluidAudio)
        return RealFluidAudioClient()
        #else
        return nil
        #endif
    }
}

#if canImport(FluidAudio)
import FluidAudio

/// Real implementation once FluidAudio is available.
private struct RealFluidAudioClient: FluidAudioClient {
    func transcribe(url: URL) async throws -> String {
        try await FluidAudio.transcribe(url: url)
    }

    func diarize(url: URL) async throws -> String {
        try await FluidAudio.diarize(url: url)
    }
}
#endif
