@testable import Overhear
import XCTest

final class NotesSaveQueueTests: XCTestCase {
    actor Recorder {
        private(set) var executions: [Int] = []
        func record(_ value: Int) { executions.append(value) }
        func values() -> [Int] { executions }
    }

    actor Gate {
        private var isOpen = false
        func open() { isOpen = true }
        func wait() async {
            while !isOpen {
                try? await Task.sleep(nanoseconds: 10_000)
            }
        }
    }

    func testConcurrentEnqueueCoalescesToLatest() async throws {
        let queue = NotesSaveQueue()
        let recorder = Recorder()
        let gate = Gate()

        // First task blocks on gate to ensure it runs before coalesced enqueues.
        let first = Task {
            await queue.enqueue {
                await gate.wait()
                await recorder.record(0)
            }
        }

        // Queue several updates while the first is waiting; they should coalesce to the latest.
        for i in 1..<5 {
            await queue.enqueue {
                await recorder.record(i)
            }
        }

        await gate.open()
        await first.value

        let values = await recorder.values()
        XCTAssertEqual(values.first, 0)
        XCTAssertEqual(values.last, 4)
        XCTAssertLessThanOrEqual(values.count, 2, "Queue should coalesce to first + latest operations")
    }

    func testSequentialEnqueueProcessesAllWhenIdle() async throws {
        let queue = NotesSaveQueue()
        let recorder = Recorder()

        await queue.enqueue {
            await recorder.record(1)
        }
        await queue.enqueue {
            await recorder.record(2)
        }

        let values = await recorder.values()
        XCTAssertEqual(values, [1, 2])
    }
}
