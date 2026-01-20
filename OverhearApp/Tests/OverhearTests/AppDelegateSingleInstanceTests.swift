import XCTest
@testable import Overhear

final class AppDelegateSingleInstanceTests: XCTestCase {
    func testSecondInstanceBlocked() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let lock1 = InstanceLock(lockDirectoryOverride: tempDir)
        let first = lock1.acquire()
        XCTAssertTrue(first, "First instance should acquire lock")

        let lock2 = InstanceLock(lockDirectoryOverride: tempDir)
        let second = lock2.acquire()
        XCTAssertFalse(second, "Second instance should be blocked by lock")

        lock1.release()
    }

    func testStaleLockIsReclaimed() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let lock1 = InstanceLock(lockDirectoryOverride: tempDir)
        XCTAssertTrue(lock1.acquire())
        lock1.release()

        let lock2 = InstanceLock(lockDirectoryOverride: tempDir)
        XCTAssertTrue(lock2.acquire(), "Should reclaim lock after first instance releases or exits")
        lock2.release()
    }
}
