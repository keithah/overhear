import XCTest
@testable import Overhear

final class MLXPreferencesTests: XCTestCase {
    func testSanitizeRejectsBadCharacters() {
        XCTAssertNil(MLXPreferences.sanitize("bad space"))
        XCTAssertNil(MLXPreferences.sanitize("bad<>"))
        XCTAssertEqual(MLXPreferences.sanitize("mlx-community/Model-1B"), "mlx-community/Model-1B")
    }

    func testModelChangeNotificationPosts() {
        let exp = expectation(description: "model change notification")
        let token = NotificationCenter.default.addObserver(forName: MLXPreferences.modelChangedNotification, object: nil, queue: nil) { _ in
            exp.fulfill()
        }
        MLXPreferences.setModelID("mlx-community/TestModel")
        wait(for: [exp], timeout: 1.0)
        NotificationCenter.default.removeObserver(token)
    }
}
