import XCTest
@testable import Overhear

final class TranscriptStoreTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        super.tearDown()
    }

    func testSaveAndRetrieveTranscript() async throws {
        let store = try TranscriptStore(storageDirectory: tempDir)
        let transcript = makeTranscript(id: "t1", date: Date())

        try await store.save(transcript)
        let retrieved = try await store.retrieve(id: "t1")
        XCTAssertEqual(retrieved.id, transcript.id)
        XCTAssertEqual(retrieved.title, transcript.title)
        XCTAssertEqual(retrieved.transcript, transcript.transcript)
    }

    func testAllTranscriptsSortedByDate() async throws {
        let store = try TranscriptStore(storageDirectory: tempDir)
        let older = makeTranscript(id: "old", date: Date().addingTimeInterval(-1000))
        let newer = makeTranscript(id: "new", date: Date())

        try await store.save(older)
        try await store.save(newer)

        let loaded = try await store.allTranscripts()
        XCTAssertEqual(loaded.map { $0.id }, ["new", "old"])
    }

    func testSearchRespectsLimitAndOffset() async throws {
        let store = try TranscriptStore(storageDirectory: tempDir)
        let baseDate = Date()
        try await store.save(makeTranscript(id: "one", date: baseDate, transcript: "alpha beta"))
        try await store.save(makeTranscript(id: "two", date: baseDate.addingTimeInterval(60), transcript: "beta gamma"))
        try await store.save(makeTranscript(id: "three", date: baseDate.addingTimeInterval(120), transcript: "alpha gamma"))

        let results = try await store.search(query: "alpha", limit: 2, offset: 0)
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(Set(results.map { $0.id }), Set(["one", "three"]))

        let offsetResults = try await store.search(query: "alpha", limit: 2, offset: 1)
        XCTAssertEqual(offsetResults.count, 1)
        XCTAssertTrue(Set(["one", "three"]).contains(offsetResults.first!.id))
    }

    private func makeTranscript(id: String, date: Date, transcript: String = "hello") -> StoredTranscript {
        StoredTranscript(
            id: id,
            meetingID: "meeting-\(id)",
            title: "Test meeting \(id)",
            date: date,
            transcript: transcript,
            duration: 300,
            audioFilePath: nil,
            segments: [],
            summary: nil
        )
    }
}
