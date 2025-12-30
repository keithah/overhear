import XCTest
@testable import Overhear

final class TranscriptStoreUpdateTests: XCTestCase {
    func testUpdateNotesPersists() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let store = try TranscriptStore(storageDirectory: tmpDir)

        let transcript = StoredTranscript(
            id: "t1",
            meetingID: "m1",
            title: "Test",
            date: Date(),
            transcript: "Hello world",
            duration: 10,
            audioFilePath: nil,
            segments: [],
            summary: nil,
            notes: nil
        )
        try await store.save(transcript)
        try await store.update(id: "t1") { existing in
            StoredTranscript(
                id: existing.id,
                meetingID: existing.meetingID,
                title: existing.title,
                date: existing.date,
                transcript: existing.transcript,
                duration: existing.duration,
                audioFilePath: existing.audioFilePath,
                segments: existing.segments,
                summary: existing.summary,
                notes: "Updated notes"
            )
        }
        let all = try await store.allTranscripts()
        let saved = all.first { $0.id == "t1" }
        XCTAssertEqual(saved?.notes, "Updated notes")
    }
}
