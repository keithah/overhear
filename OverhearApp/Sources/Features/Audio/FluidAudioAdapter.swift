import Foundation

/// Protocol that represents a FluidAudio diarization client.
protocol FluidAudioClient: Sendable {
    func diarize(url: URL) async throws -> String
}

enum FluidAudioAdapter {
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

private struct RealFluidAudioClient: FluidAudioClient {
    func diarize(url: URL) async throws -> String {
        // Placeholder until FluidAudio API is wired up.
        return ""
    }
}
#endif
