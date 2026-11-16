import XCTest
@testable import NetMon

final class PrefsMigrationTests: XCTestCase {
    func testCopiesLegacySettingsOnceWithoutOverwriting() throws {
        let suite = "netmon.tests.\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        d.set(99.0, forKey: Prefs.Key.latencyAlertMs)

        Prefs.migrateLegacySettings(from: [Prefs.Key.targets: "1.1.1.1, 9.9.9.9", Prefs.Key.latencyAlertMs: 150.0,
                                           "unrelated": true], into: d, domain: suite)
        XCTAssertEqual(d.string(forKey: Prefs.Key.targets), "1.1.1.1, 9.9.9.9")
        XCTAssertEqual(d.double(forKey: Prefs.Key.latencyAlertMs), 99, "existing values win")
        XCTAssertNil(d.object(forKey: "unrelated"), "only known settings are copied")

        Prefs.migrateLegacySettings(from: [Prefs.Key.historyDays: 30], into: d, domain: suite)
        XCTAssertNil(d.persistentDomain(forName: suite)?[Prefs.Key.historyDays], "runs only once")
    }
}
