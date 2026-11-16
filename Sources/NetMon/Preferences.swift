import Foundation

/// UserDefaults keys and defaults. Views bind with `@AppStorage(Prefs.Key.x)`; monitors
/// read the live value each cycle so changes take effect without a restart.
enum Prefs {
    static let bundleID = "com.babyscripts.netmon"
    /// The bundle id before the rename; settings saved under it are copied over once.
    static let legacyBundleID = "me.craig.netmon"

    enum Key {
        static let targets = "targets"
        static let pingInterval = "pingInterval"
        static let traceInterval = "traceInterval"
        static let maxHops = "maxHops"
        static let lossAlertPercent = "lossAlertPercent"
        static let latencyAlertMs = "latencyAlertMs"
        static let jitterAlertMs = "jitterAlertMs"
        static let notificationsEnabled = "notificationsEnabled"
        static let notifyPathFindings = "notifyPathFindings"
        static let autoSpeedTest = "autoSpeedTest"
        static let speedTestCooldownMinutes = "speedTestCooldownMinutes"
        static let minDownloadMbps = "minDownloadMbps"
        static let historyDays = "historyDays"
    }

    /// Every settings key, for migration.
    static let allKeys = [Key.targets, Key.pingInterval, Key.traceInterval, Key.maxHops, Key.lossAlertPercent,
                          Key.latencyAlertMs, Key.jitterAlertMs, Key.notificationsEnabled, Key.notifyPathFindings,
                          Key.autoSpeedTest, Key.speedTestCooldownMinutes, Key.minDownloadMbps, Key.historyDays]

    /// Copies settings saved under the legacy bundle id (`old`) into `defaults`, whose
    /// saved values live in `domain`, once, without overwriting anything already saved.
    static func migrateLegacySettings(from old: [String: Any], into defaults: UserDefaults, domain: String) {
        let marker = "migratedFrom.\(legacyBundleID)"
        guard !defaults.bool(forKey: marker) else { return }
        // Check the saved domain, not object(forKey:), which also sees registered defaults.
        let saved = defaults.persistentDomain(forName: domain) ?? [:]
        for key in allKeys where saved[key] == nil {
            if let value = old[key] { defaults.set(value, forKey: key) }
        }
        defaults.set(true, forKey: marker)
    }

    static func register() {
        // Only the real app migrates; tests and `swift run` have other defaults domains.
        if Bundle.main.bundleIdentifier == bundleID {
            let d = UserDefaults.standard
            migrateLegacySettings(from: d.persistentDomain(forName: legacyBundleID) ?? [:], into: d, domain: bundleID)
        }
        UserDefaults.standard.register(defaults: [
            Key.targets: "1.1.1.1, 8.8.8.8",
            Key.pingInterval: 1.0,
            Key.traceInterval: 2.0,
            Key.maxHops: 30,
            Key.lossAlertPercent: 5.0,
            Key.latencyAlertMs: 150.0,
            Key.jitterAlertMs: 40.0,
            Key.notificationsEnabled: true,
            Key.notifyPathFindings: true,
            // Speed tests never run on a timer: only on demand, or when another signal (an alert)
            // suggests a problem. Each run saturates the link and moves hundreds of MB or more.
            Key.autoSpeedTest: true,
            Key.speedTestCooldownMinutes: 60.0,
            Key.minDownloadMbps: 0.0,         // 0 = no throughput alert
            Key.historyDays: 7,
        ])
    }

    private static var d: UserDefaults { .standard }

    static var targets: [String] {
        d.string(forKey: Key.targets)!
            .split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .map(String.init)
            .filter { !$0.isEmpty }
    }
    static var pingInterval: Double { max(0.2, d.double(forKey: Key.pingInterval)) }
    static var traceInterval: Double { max(0.5, d.double(forKey: Key.traceInterval)) }
    static var maxHops: Int { min(64, max(1, d.integer(forKey: Key.maxHops))) }
    static var lossAlertPercent: Double { d.double(forKey: Key.lossAlertPercent) }
    static var latencyAlertMs: Double { d.double(forKey: Key.latencyAlertMs) }
    static var jitterAlertMs: Double { d.double(forKey: Key.jitterAlertMs) }
    static var notificationsEnabled: Bool { d.bool(forKey: Key.notificationsEnabled) }
    static var notifyPathFindings: Bool { d.bool(forKey: Key.notifyPathFindings) }
    static var autoSpeedTest: Bool { d.bool(forKey: Key.autoSpeedTest) }
    static var speedTestCooldownMinutes: Double { max(5, d.double(forKey: Key.speedTestCooldownMinutes)) }
    static var minDownloadMbps: Double { d.double(forKey: Key.minDownloadMbps) }
    static var historyDays: Int { max(1, d.integer(forKey: Key.historyDays)) }
}
