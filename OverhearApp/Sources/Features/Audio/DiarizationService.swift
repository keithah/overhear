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
            let segments = try await engine.diarize(audioURL: audioURL)
            diarizationLogger.info("Diarization returned \(segments.count) speaker segments")
            FileLogger.log(
                category: "DiarizationService",
                message: "Diarization returned \(segments.count) segments for \(audioURL.lastPathComponent)"
            )
            return segments
        } catch {
            diarizationLogger.error("Diarization failed: \(error.localizedDescription, privacy: .public)")
            FileLogger.log(
                category: "DiarizationService",
                message: "Diarization failed: \(error.localizedDescription)"
            )
            return []
        }
    }
}
