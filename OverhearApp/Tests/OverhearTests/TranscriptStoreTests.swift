import XCTest
@testable import Overhear

final class TranscriptStoreTests: XCTestCase {
    override func setUp() async throws {
        // Ensure storage is enabled for tests unless overridden.
        setenv("OVERHEAR_DISABLE_TRANSCRIPT_STORAGE", "0", 1)
    }

    func testSaveAndRetrieveRoundTrip() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try TranscriptStore(storageDirectory: tmpDir)
        let transcript = StoredTranscript(
            id: "t1",
            meetingID: "m1",
            title: "Unit Test Meeting",
            date: Date(),
            transcript: "Hello world",
            duration: 60,
            audioFilePath: nil
        )

        try await store.save(transcript)
        let loaded = try await store.retrieve(id: "t1")
        XCTAssertEqual(loaded.id, transcript.id)
        XCTAssertEqual(loaded.transcript, transcript.transcript)
    }

    func testSearchHonorsLimitAndOffset() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try TranscriptStore(storageDirectory: tmpDir)

        for i in 0..<5 {
            let transcript = StoredTranscript(
                id: "t\(i)",
                meetingID: "m\(i)",
                title: "Sample \(i)",
                date: Date().addingTimeInterval(TimeInterval(i)),
                transcript: i % 2 == 0 ? "foo bar" : "baz qux",
                duration: 30,
                audioFilePath: nil
            )
            try await store.save(transcript)
        }

        let firstPage = try await store.search(query: "foo", limit: 1, offset: 0)
        let secondPage = try await store.search(query: "foo", limit: 1, offset: 1)

        XCTAssertEqual(firstPage.count, 1)
        XCTAssertEqual(secondPage.count, 1)
        XCTAssertNotEqual(firstPage.first?.id, secondPage.first?.id)
    }

    func testStorageDisabledThrows() async throws {
        setenv("OVERHEAR_DISABLE_TRANSCRIPT_STORAGE", "1", 1)
        await XCTAssertThrowsError(try TranscriptStore(storageDirectory: FileManager.default.temporaryDirectory)) { error in
            guard case TranscriptStore.Error.storageDisabled = error else {
                return XCTFail("Expected storageDisabled, got \(error)")
            }
        }
    }
}
