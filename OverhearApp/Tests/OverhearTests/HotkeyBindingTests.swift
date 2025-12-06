import XCTest
@testable import Overhear

final class HotkeyBindingTests: XCTestCase {
    func testParsingHotkeyWithModifiers() {
        let binding = HotkeyBinding(string: "⌃⇧K", action: {})
        XCTAssertNotNil(binding)
        XCTAssertEqual(binding?.modifiers, [.control, .shift])
        XCTAssertEqual(binding?.key, "k")
    }

    func testParsingPlainKey() {
        let binding = HotkeyBinding(string: "G", action: {})
        XCTAssertNotNil(binding)
        XCTAssertEqual(binding?.modifiers, [])
        XCTAssertEqual(binding?.key, "g")
    }

    func testRejectsEmptyString() {
        let binding = HotkeyBinding(string: "   ", action: {})
        XCTAssertNil(binding)
    }

    func testMatchesHotkey() {
        let binding = HotkeyBinding(string: "⌘⌥J", action: {})
        XCTAssertNotNil(binding)
        XCTAssertTrue(binding!.matches(flags: [.command, .option], key: "j"))
        XCTAssertFalse(binding!.matches(flags: [.command], key: "j"))
        XCTAssertFalse(binding!.matches(flags: [.command, .option], key: "k"))
    }
}
