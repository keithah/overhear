import XCTest
@testable import Overhear

final class PreferencesServiceTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "com.overhear.tests.preferences.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        if let name = suiteName {
            defaults.removePersistentDomain(forName: name)
        }
        defaults = nil
        super.tearDown()
    }

    func testToggleCalendarPersistsSelection() async {
        let suiteNameRef = suiteName!
        let service = await MainActor.run {
            PreferencesService(userDefaults: UserDefaults(suiteName: suiteNameRef)!)
        }
        await MainActor.run {
            service.toggleCalendar(id: "cal-1", enabled: true)
            service.toggleCalendar(id: "cal-2", enabled: true)
        }

        let stored = defaults.array(forKey: "selectedCalendars") as? [String] ?? []
        XCTAssertEqual(Set(stored), ["cal-1", "cal-2"])

        await MainActor.run {
            service.toggleCalendar(id: "cal-1", enabled: false)
        }

        let updated = defaults.array(forKey: "selectedCalendars") as? [String] ?? []
        XCTAssertEqual(Set(updated), ["cal-2"])
    }

    func testInitializeWithAllCalendarsSetsWhenEmpty() async {
        let suiteNameRef = suiteName!
        let service = await MainActor.run {
            PreferencesService(userDefaults: UserDefaults(suiteName: suiteNameRef)!)
        }
        let initialSet = await MainActor.run { service.selectedCalendarIDs }
        XCTAssertTrue(initialSet.isEmpty)

        await MainActor.run {
            service.initializeWithAllCalendars(["a", "b", "c"])
        }

        let storedSet = await MainActor.run { service.selectedCalendarIDs }
        XCTAssertEqual(storedSet, Set(["a", "b", "c"]))
    }

    func testTimeFormatterUses24HourWhenEnabled() async {
        defaults.set(true, forKey: "use24HourClock")
        let suiteNameRef = suiteName!
        let service = await MainActor.run {
            PreferencesService(userDefaults: UserDefaults(suiteName: suiteNameRef)!)
        }
        let formatter = await MainActor.run { service.timeFormatter }
        XCTAssertEqual(formatter.dateFormat, "HH:mm")
    }

    func testOpenBehaviorReflectsStoredValue() async {
        defaults.set(OpenBehavior.brave.rawValue, forKey: "meetOpenBehavior")
        let suiteNameRef = suiteName!
        let service = await MainActor.run {
            PreferencesService(userDefaults: UserDefaults(suiteName: suiteNameRef)!)
        }
        let behavior = await MainActor.run {
            service.openBehavior(for: .meet)
        }
        XCTAssertEqual(behavior, .brave)
    }
}
