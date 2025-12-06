import Foundation

enum DiarizationEngineFactory {
    static func makeEngine() -> any DiarizationEngine {
        let useFluid = ProcessInfo.processInfo.environment["OVERHEAR_USE_FLUIDAUDIO"] == "1"
        if useFluid, let fluid = FluidAudioAdapter.makeClient() {
            return FluidAudioDiarizationEngine(fluid: fluid)
        }
        return LegacyDiarizationEngine()
    }
}

private struct FluidAudioDiarizationEngine: DiarizationEngine {
    let fluid: FluidAudioClient
    func diarize(audioURL: URL) async throws -> String {
        try await fluid.diarize(url: audioURL)
    }
}

private struct LegacyDiarizationEngine: DiarizationEngine {
    func diarize(audioURL: URL) async throws -> String {
        // Placeholder for future diarization logic; currently returns an empty transcript.
        return ""
    }
}
