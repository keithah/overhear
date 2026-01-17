@testable import Overhear
import XCTest

final class NotesSaveQueueTests: XCTestCase {
    actor Recorder {
        private(set) var executions: [Int] = []
        func record(_ value: Int) { executions.append(value) }
        func values() -> [Int] { executions }
    }

    func testConcurrentEnqueueCoalescesToLatest() async throws {
        let queue = NotesSaveQueue()
        let recorder = Recorder()

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<5 {
                group.addTask {
                    await queue.enqueue {
                        await recorder.record(i)
                    }
                }
            }
        }

        let values = await recorder.values()
        XCTAssertEqual(values.first, 0)
        XCTAssertEqual(values.last, 4)
        XCTAssertLessThanOrEqual(values.count, 2, "Queue should coalesce to first + latest operations")
    }
}
