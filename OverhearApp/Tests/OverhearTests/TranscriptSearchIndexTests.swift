import XCTest
@testable import Overhear

final class TranscriptSearchIndexTests: XCTestCase {
    func testSearchHandlesPunctuationAndNormalizes() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let index = try TranscriptSearchIndex(baseDirectory: tempDir)
        let transcript = StoredTranscript(
            id: "t1",
            meetingID: "m1",
            title: "Q&A: Planning 2024",
            date: Date(),
            transcript: "Contact user@company.com for details",
            duration: 10,
            audioFilePath: nil,
            segments: [],
            summary: nil,
            notes: nil
        )
        try index.index(transcript: transcript, fileURL: tempDir.appendingPathComponent("t1.json"))

        // Punctuation and email should not be stripped entirely.
        let results1 = try index.search(query: "Q&A", limit: 10, offset: 0)
        XCTAssertEqual(results1.count, 1)
        let results2 = try index.search(query: "user@company.com", limit: 10, offset: 0)
        XCTAssertEqual(results2.count, 1)
    }

    func testSearchLongQueryNoWildcardScan() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let index = try TranscriptSearchIndex(baseDirectory: tempDir)
        let transcript = StoredTranscript(
            id: "t2",
            meetingID: "m2",
            title: "Weekly Sync",
            date: Date(),
            transcript: "Weekly status update",
            duration: 10,
            audioFilePath: nil,
            segments: [],
            summary: nil,
            notes: nil
        )
        try index.index(transcript: transcript, fileURL: tempDir.appendingPathComponent("t2.json"))

        let longQuery = String(repeating: "a", count: 120)
        let results = try index.search(query: longQuery, limit: 10, offset: 0)
        XCTAssertTrue(results.isEmpty, "Long query should not wildcard scan and should not match")
    }
}
