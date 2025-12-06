import Foundation
import os.log

private let diarizationLogger = Logger(subsystem: "com.overhear.app", category: "DiarizationService")

actor DiarizationService {
    private let engine: DiarizationEngine

    init(engine: DiarizationEngine = DiarizationEngineFactory.makeEngine()) {
        self.engine = engine
    }

    func analyze(audioURL: URL) async -> [SpeakerSegment] {
        do {
            let payload = try await engine.diarize(audioURL: audioURL)
            diarizationLogger.info("Diarization result: \(payload)")
            return parse(payload)
        } catch {
            diarizationLogger.error("Diarization failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    private func parse(_ payload: String) -> [SpeakerSegment] {
        // TODO: parse FluidAudio diarization JSON/CSV output. Placeholder currently returns empty.
        []
    }
}
