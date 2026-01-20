@testable import Overhear
import XCTest

@MainActor
final class DebouncerTests: XCTestCase {

    func testDebouncerRunsOnlyLatestAction() async throws {
        let debouncer = Debouncer()
        var value = 0

        debouncer.schedule(delayNanoseconds: 50_000_000) { @MainActor in
            value = 1
        }
        debouncer.schedule(delayNanoseconds: 50_000_000) { @MainActor in
            value = 2
        }

        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertEqual(value, 2)
    }

    func testDebouncerCancelPreventsAction() async throws {
        let debouncer = Debouncer()
        var fired = false

        debouncer.schedule(delayNanoseconds: 50_000_000) { @MainActor in
            fired = true
        }
        debouncer.cancel()

        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertFalse(fired)
    }
}
