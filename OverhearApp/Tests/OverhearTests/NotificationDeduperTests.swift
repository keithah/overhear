import XCTest
@testable import Overhear

final class NotificationDeduperTests: XCTestCase {
    func testDeduperBoundsAndUniqueness() {
        var deduper = NotificationDeduper(maxEntries: 3)
        XCTAssertTrue(deduper.record("a"))
        XCTAssertFalse(deduper.record("a"), "Duplicate should not be handled")
        XCTAssertTrue(deduper.record("b"))
        XCTAssertTrue(deduper.record("c"))
        XCTAssertTrue(deduper.record("d"), "Should evict oldest when over capacity")
        // "a" should have been evicted; recording again should be treated as new.
        XCTAssertTrue(deduper.record("a"))
    }

    func testDeduperExpiresOldEntries() {
        var now = Date()
        var deduper = NotificationDeduper(maxEntries: 3, dateProvider: { now })
        XCTAssertTrue(deduper.record("old"))
        // Advance time beyond TTL
        now.addTimeInterval(4000)
        XCTAssertTrue(deduper.record("old"), "Expired entries should allow re-recording")
    }
}
