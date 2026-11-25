import AppKit
import Observation

enum TimeRange: String, CaseIterable, Identifiable {
    case m15 = "15m", h1 = "1h", h24 = "24h", d7 = "7d"
    var id: String { rawValue }
    var seconds: TimeInterval {
        switch self {
        case .m15: 900
        case .h1: 3600
        case .h24: 86_400
        case .d7: 604_800
        }
    }
    var bucket: TimeInterval {
        switch self {
        case .m15: 5
        case .h1: 15
        case .h24: 300
        case .d7: 1800
        }
    }
    /// Short ranges chart raw samples; long ranges chart persisted minute rollups.
    var usesRawSamples: Bool { seconds <= TargetMonitor.sampleRetention }
}

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    private(set) var monitors: [TargetMonitor] = []
    private(set) var rollups: [MinuteRollup] = []
    private(set) var throughputHistory: [ThroughputResult] = []
    private(set) var events: [NetEvent] = []
    private(set) var speedTestRunning = false
    private(set) var speedTestError: String?
    /// Whether the Mac currently has working global IPv6. IPv6 twins are monitored only then.
    private(set) var ipv6Available = false
    /// Section shown in the main window; settable from the API so Claude can show a screen.
    var selectedSection: SidebarItem? = .overview

    /// Opens the main window. Captured from a view, since openWindow is only in the SwiftUI environment.
    @ObservationIgnored var openMainWindow: (() -> Void)?

    @ObservationIgnored let store = HistoryStore()
    /// Wi-Fi link, neighbor scans and channel analysis. Observable on its own.
    @ObservationIgnored private(set) lazy var wifi = WiFiMonitor(model: self)
    @ObservationIgnored private lazy var alerts = AlertManager(model: self)
    @ObservationIgnored private var started = false
    @ObservationIgnored private lazy var api = LocalAPIServer { request in
        await APIRoutes.handle(request)
    }

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        Prefs.register()
        let cutoff = Date().addingTimeInterval(-Double(Prefs.historyDays) * 86_400)
        rollups = store.load(MinuteRollup.self, from: "rollups", keepingAfter: cutoff) { $0.start }
        throughputHistory = store.load(ThroughputResult.self, from: "throughput", keepingAfter: cutoff.addingTimeInterval(-23 * 86_400)) { $0.date }
        events = store.load(NetEvent.self, from: "events", keepingAfter: cutoff) { $0.date }
        applyTargets()
        wifi.start(loadingAfter: cutoff)
        alerts.start()
        api.start()
        watchIPv6()
    }

    /// Well-known IPv6 addresses of the usual IPv4 targets, so each gets a twin on the same network.
    static let ipv6Twins: [String: String] = [
        "1.1.1.1": "2606:4700:4700::1111", "1.0.0.1": "2606:4700:4700::1001",
        "8.8.8.8": "2001:4860:4860::8888", "8.8.4.4": "2001:4860:4860::8844",
        "9.9.9.9": "2620:fe::fe", "149.112.112.112": "2620:fe::9",
        "208.67.222.222": "2620:119:35::35", "208.67.220.220": "2620:119:53::53",
    ]

    /// The IPv6 twin to monitor for a configured target: the known address for a well-known
    /// IPv4 address, the hostname's AAAA record for a hostname, none for other literals.
    static func ipv6Twin(of target: String) -> (host: String, lookup: String)? {
        if let v6 = ipv6Twins[target] { return (v6, v6) }
        return IPFamily(address: target) == nil ? ("\(target) (IPv6)", target) : nil
    }

    /// Re-checks IPv6 every 30 s and adds or removes the IPv6 twins when it comes or goes.
    private func watchIPv6() {
        Task {
            var checked = false
            while !Task.isCancelled {
                let available = await Task.detached(priority: .utility) { Resolver.hasGlobalIPv6() }.value
                if available != ipv6Available {
                    ipv6Available = available
                    applyTargets()
                    // The first check is just learning the starting state, not a change.
                    if checked { alerts.ipv6Changed(available: available, twins: monitors.filter { $0.twinOf != nil }.map(\.host)) }
                }
                checked = true
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    /// (Re)builds monitors from the targets preference, keeping ones that didn't change.
    /// Each configured target is followed by its IPv6 twin while IPv6 is available.
    func applyTargets() {
        var wanted: [(host: String, lookup: String, family: IPFamily, twinOf: String?)] = []
        for target in Prefs.targets {
            wanted.append((target, target, IPFamily(address: target) ?? .v4, nil))
            if ipv6Available, let twin = Self.ipv6Twin(of: target) { wanted.append((twin.host, twin.lookup, .v6, target)) }
        }
        var seen = Set<String>()
        wanted = wanted.filter { seen.insert($0.host).inserted }

        let existing = Dictionary(uniqueKeysWithValues: monitors.map { ($0.host, $0) })
        for m in monitors where !seen.contains(m.host) { m.stop() }
        monitors = wanted.map { w in
            if let m = existing[w.host] { return m }
            let m = TargetMonitor(host: w.host, lookup: w.lookup, family: w.family, twinOf: w.twinOf)
            m.onRollup = { [weak self] r in self?.addRollup(r) }
            m.start()
            return m
        }
    }

    private func addRollup(_ r: MinuteRollup) {
        rollups.append(r)
        store.append(r, to: "rollups")
        let cutoff = Date().addingTimeInterval(-Double(Prefs.historyDays) * 86_400)
        if let first = rollups.first, first.start < cutoff { rollups.removeAll { $0.start < cutoff } }
    }

    func sendTestNotification() { alerts.sendTest() }

    /// Brings the main window to the front on `section`. Returns false if no view has
    /// registered the window opener yet.
    func showWindow(_ section: SidebarItem) -> Bool {
        guard let openMainWindow else { return false }
        selectedSection = section
        openMainWindow()
        NSApp.activate()
        return true
    }

    func record(_ event: NetEvent) {
        events.append(event)
        store.append(event, to: "events")
        if events.count > 2000 { events.removeFirst(events.count - 2000) }
    }

    // MARK: Aggregates

    var overallHealth: Health {
        let states = monitors.map(\.health).filter { $0 != .unknown }
        guard !states.isEmpty else { return .unknown }
        if states.allSatisfy({ $0 == .down }) { return .down }
        return states.contains { $0 != .ok } ? .degraded : .ok
    }

    /// Latency shown in the menu bar: best recent average across targets.
    var headlineLatency: Double? {
        monitors.compactMap { $0.stats(lastSeconds: 10).avg }.min()
    }

    /// Chart points for `range`, in the range's own bucket size unless `bucket` overrides it.
    func chartPoints(for monitor: TargetMonitor, range: TimeRange, bucket: TimeInterval? = nil) -> [ChartPoint] {
        let cutoff = Date().addingTimeInterval(-range.seconds)
        let size = bucket ?? range.bucket
        if range.usesRawSamples {
            return Bucketing.fromSamples(monitor.samples.filter { $0.t >= cutoff }, target: monitor.host, bucket: size)
        }
        return Bucketing.fromRollups(rollups.filter { $0.target == monitor.host && $0.start >= cutoff },
                                     target: monitor.host, bucket: size)
    }

    func rangeStats(for monitor: TargetMonitor, range: TimeRange) -> ProbeStats {
        if range.usesRawSamples { return monitor.stats(lastSeconds: range.seconds) }
        let cutoff = Date().addingTimeInterval(-range.seconds)
        let rs = rollups.filter { $0.target == monitor.host && $0.start >= cutoff }
        var s = ProbeStats()
        s.sent = rs.reduce(0) { $0 + $1.sent }
        s.received = rs.reduce(0) { $0 + $1.received }
        s.best = rs.compactMap(\.min).min()
        s.worst = rs.compactMap(\.max).max()
        let weighted = rs.compactMap { r in r.avg.map { ($0 * Double(r.received), r.received) } }
        let n = weighted.reduce(0) { $0 + $1.1 }
        s.avg = n > 0 ? weighted.reduce(0) { $0 + $1.0 } / Double(n) : nil
        let jitters = rs.compactMap(\.jitter)
        s.jitter = jitters.isEmpty ? nil : jitters.reduce(0, +) / Double(jitters.count)
        return s
    }

    // MARK: Throughput

    var lastThroughput: ThroughputResult? { throughputHistory.last }

    /// True during a speed test and for a minute after (the alert window is 60s). The test saturates the
    /// link, so latency alerts and hop stats from this window would be self-inflicted.
    var inSpeedTestQuietPeriod: Bool {
        speedTestRunning || speedTestEndedAt.map { Date().timeIntervalSince($0) < 60 } ?? false
    }
    /// Speed test or Wi-Fi scan: either disturbs latency, so alerts and hop stats pause.
    var inMeasurementQuietPeriod: Bool { inSpeedTestQuietPeriod || wifi.inScanQuietPeriod }
    @ObservationIgnored private var speedTestEndedAt: Date?
    @ObservationIgnored private var lastAutoSpeedTest: Date?

    /// Called when another signal (an alert) suggests a problem. Measures throughput to see
    /// whether the problem affects bandwidth, at most once per cooldown period.
    func triggerSpeedTest(reason: String) {
        guard Prefs.autoSpeedTest, !speedTestRunning else { return }
        let cooldown = Prefs.speedTestCooldownMinutes * 60
        let lastRun = [lastAutoSpeedTest, lastThroughput?.date].compactMap { $0 }.max()
        if let lastRun, Date().timeIntervalSince(lastRun) < cooldown { return }
        lastAutoSpeedTest = Date()
        record(NetEvent(date: Date(), level: .info, title: "Running speed test", detail: "Triggered by: \(reason)"))
        runSpeedTest()
    }

    func runSpeedTest() {
        guard !speedTestRunning else { return }
        // Set synchronously so a second caller in the same tick joins this run.
        speedTestRunning = true
        speedTestError = nil
        speedTestTask = Task { await performSpeedTest() }
    }

    /// Starts a speed test (or joins the one already running) and waits for its result.
    func runSpeedTestAndWait() async -> Result<ThroughputResult, Error> {
        if !speedTestRunning { runSpeedTest() }
        return await speedTestTask?.value ?? .failure(ThroughputTester.Failure(message: "speed test did not start"))
    }

    @ObservationIgnored private var speedTestTask: Task<Result<ThroughputResult, Error>, Never>?

    private func performSpeedTest() async -> Result<ThroughputResult, Error> {
        defer { speedTestRunning = false; speedTestEndedAt = Date() }
        do {
            let result = try await ThroughputTester.run()
            throughputHistory.append(result)
            store.append(result, to: "throughput")
            record(NetEvent(date: result.date, level: .info, title: "Speed test",
                            detail: String(format: "↓ %.0f Mbps  ↑ %.0f Mbps  responsiveness %.0f RPM (%@)",
                                           result.downloadMbps, result.uploadMbps,
                                           result.responsivenessRPM ?? 0, result.responsivenessRating)))
            alerts.checkThroughput(result)
            return .success(result)
        } catch {
            speedTestError = error.localizedDescription
            record(NetEvent(date: Date(), level: .warning, title: "Speed test failed", detail: error.localizedDescription))
            return .failure(error)
        }
    }
}
