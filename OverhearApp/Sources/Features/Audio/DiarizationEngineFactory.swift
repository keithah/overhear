import Foundation

enum DiarizationEngineFactory {
    static func makeEngine() -> any DiarizationEngine {
        let useFluid = FluidAudioAdapter.isEnabled
        if useFluid, let fluid = FluidAudioAdapter.makeClient() {
            FileLogger.log(category: "DiarizationService", message: "Using FluidAudio diarization engine")
            return FluidAudioDiarizationEngine(fluid: fluid)
        }
        FileLogger.log(category: "DiarizationService", message: "Using legacy diarization engine (no FluidAudio)")
        return LegacyDiarizationEngine()
    }
}

private struct FluidAudioDiarizationEngine: DiarizationEngine {
    let fluid: FluidAudioClient
    func diarize(audioURL: URL) async throws -> [SpeakerSegment] {
        do {
            let segments = try await fluid.diarize(url: audioURL)
            FileLogger.log(
                category: "DiarizationService",
                message: "FluidAudio diarize returned \(segments.count) segments for \(audioURL.lastPathComponent)"
            )
            return segments
        } catch {
            FileLogger.log(
                category: "DiarizationService",
                message: "FluidAudio diarization failed: \(error.localizedDescription); falling back to no-op"
            )
            return []
        }
    }
}

private struct LegacyDiarizationEngine: DiarizationEngine {
    func diarize(audioURL: URL) async throws -> [SpeakerSegment] {
        FileLogger.log(
            category: "DiarizationService",
            message: "Legacy diarization returning empty for \(audioURL.lastPathComponent)"
        )
        return []
    }
}
