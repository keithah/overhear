import XCTest
@testable import Overhear

@MainActor
final class NotificationDeduperTests: XCTestCase {
    func testDeduperBoundsAndUniqueness() async {
        let deduper = NotificationDeduper(maxEntries: 3)
        var handled = await deduper.record("a")
        XCTAssertTrue(handled)
        handled = await deduper.record("a")
        XCTAssertFalse(handled, "Duplicate should not be handled")
        handled = await deduper.record("b")
        XCTAssertTrue(handled)
        handled = await deduper.record("c")
        XCTAssertTrue(handled)
        handled = await deduper.record("d")
        XCTAssertTrue(handled, "Should evict oldest when over capacity")
        // "a" should have been evicted; recording again should be treated as new.
        handled = await deduper.record("a")
        XCTAssertTrue(handled)
    }
}
