import XCTest
@testable import Overhear

final class AppDelegateSingleInstanceTests: XCTestCase {
    func testSecondInstanceBlocked() async {
        let appDelegate = AppDelegate()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let first = await MainActor.run { appDelegate.enforceSingleInstance(lockDirectoryOverride: tempDir) }
        XCTAssertTrue(first, "First instance should acquire lock")

        let second = await MainActor.run { appDelegate.enforceSingleInstance(lockDirectoryOverride: tempDir) }
        XCTAssertFalse(second, "Second instance should be blocked by lock")

        await MainActor.run {
            appDelegate.applicationWillTerminate(Notification(name: Notification.Name("test")))
        }
    }

    func testStaleLockIsReclaimed() async {
        let appDelegate = AppDelegate()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let first = await MainActor.run { appDelegate.enforceSingleInstance(lockDirectoryOverride: tempDir) }
        XCTAssertTrue(first)
        await MainActor.run {
            appDelegate.applicationWillTerminate(Notification(name: Notification.Name("test")))
        }
        let second = await MainActor.run { appDelegate.enforceSingleInstance(lockDirectoryOverride: tempDir) }
        XCTAssertTrue(second, "Should reclaim stale lock after first instance exits")
    }
}
