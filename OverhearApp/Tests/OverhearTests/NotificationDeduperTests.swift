import XCTest
@testable import Overhear

@MainActor
final class NotificationDeduperTests: XCTestCase {
    func testDeduperBoundsAndUniqueness() {
        let deduper = NotificationDeduper(maxEntries: 3)
        XCTAssertTrue(deduper.record("a"))
        XCTAssertFalse(deduper.record("a"), "Duplicate should not be handled")
        XCTAssertTrue(deduper.record("b"))
        XCTAssertTrue(deduper.record("c"))
        XCTAssertTrue(deduper.record("d"), "Should evict oldest when over capacity")
        // "a" should have been evicted; recording again should be treated as new.
        XCTAssertTrue(deduper.record("a"))
    }
}
