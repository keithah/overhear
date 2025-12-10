import Foundation

enum DiarizationEngineFactory {
    static func makeEngine() -> any DiarizationEngine {
        let useFluid = FluidAudioAdapter.isEnabled
        if useFluid, let fluid = FluidAudioAdapter.makeClient() {
            return FluidAudioDiarizationEngine(fluid: fluid)
        }
        return LegacyDiarizationEngine()
    }
}

private struct FluidAudioDiarizationEngine: DiarizationEngine {
    let fluid: FluidAudioClient
    func diarize(audioURL: URL) async throws -> [SpeakerSegment] {
        try await fluid.diarize(url: audioURL)
    }
}

private struct LegacyDiarizationEngine: DiarizationEngine {
    func diarize(audioURL: URL) async throws -> [SpeakerSegment] {
        []
    }
}
