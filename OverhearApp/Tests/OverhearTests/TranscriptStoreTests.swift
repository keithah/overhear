import XCTest
@testable import Overhear

final class TranscriptStoreTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        setenv("OVERHEAR_DISABLE_TRANSCRIPT_STORAGE", "0", 1)
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        unsetenv("OVERHEAR_DISABLE_TRANSCRIPT_STORAGE")
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        super.tearDown()
    }

    func testSaveAndRetrieveTranscript() async throws {
        let store = try TranscriptStore(storageDirectory: tempDir)
        let segments = [
            SpeakerSegment(speaker: "Alex", start: 0, end: 60),
            SpeakerSegment(speaker: "Jamie", start: 60, end: 120)
        ]
        let summary = MeetingSummary(summary: "Takeaways",
                                     highlights: ["Hello world", "Wrap up"],
                                     actionItems: [])
        let transcript = makeTranscript(id: "t1", date: Date(), transcript: "hello", segments: segments, summary: summary)

        try await store.save(transcript)
        let retrieved = try await store.retrieve(id: "t1")
        XCTAssertEqual(retrieved.id, transcript.id)
        XCTAssertEqual(retrieved.title, transcript.title)
        XCTAssertEqual(retrieved.transcript, transcript.transcript)
        XCTAssertEqual(retrieved.segments, segments)
        XCTAssertEqual(retrieved.summary, summary)
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

    func testKeychainBypassUsesSharedEphemeralKey() async throws {
        setenv("OVERHEAR_INSECURE_NO_KEYCHAIN", "1", 1)
        defer {
            unsetenv("OVERHEAR_INSECURE_NO_KEYCHAIN")
        }

        let store1 = try TranscriptStore(storageDirectory: tempDir)
        let transcript = makeTranscript(id: "ephemeral", date: Date(), transcript: "hello")
        try await store1.save(transcript)

        // Second instance should reuse the same in-process ephemeral key.
        let store2 = try TranscriptStore(storageDirectory: tempDir)
        let loaded = try await store2.retrieve(id: "ephemeral")
        XCTAssertEqual(loaded.transcript, "hello")
    }

    func testKeychainBypassRequiresExplicitOverride() async throws {
        setenv("CI", "true", 1)
        setenv("GITHUB_ACTIONS", "false", 1)
        defer {
            unsetenv("CI")
            unsetenv("GITHUB_ACTIONS")
        }
        // With no explicit override, bypass should be false => initialization should try Keychain.
        // We can't assert the Keychain path directly, but we can assert the bypass flag logic indirectly by
        // ensuring no crash; this test documents the expectation.
        _ = try TranscriptStore(storageDirectory: tempDir)
    }

    private func makeTranscript(id: String,
                                date: Date,
                                transcript: String = "hello",
                                segments: [SpeakerSegment] = [],
                                summary: MeetingSummary? = nil) -> StoredTranscript {
        StoredTranscript(
            id: id,
            meetingID: "meeting-\(id)",
            title: "Test meeting \(id)",
            date: date,
            transcript: transcript,
            duration: 300,
            audioFilePath: nil,
            segments: segments,
            summary: summary,
            notes: nil
        )
    }
}
