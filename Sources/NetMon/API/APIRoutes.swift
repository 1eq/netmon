import Foundation

// MARK: Response shapes (camelCase JSON, milliseconds rounded to 0.1)

private func r1(_ v: Double?) -> Double? { v.map { ($0 * 10).rounded() / 10 } }

struct StatsDTO: Encodable {
    let sent: Int
    let received: Int
    let lossPercent: Double
    let lastMs, avgMs, minMs, maxMs, stdevMs, jitterMs: Double?

    init(_ s: ProbeStats) {
        sent = s.sent
        received = s.received
        lossPercent = r1(s.lossPercent) ?? 0
        lastMs = r1(s.last); avgMs = r1(s.avg); minMs = r1(s.best); maxMs = r1(s.worst)
        stdevMs = r1(s.stdev); jitterMs = r1(s.jitter)
    }
}

struct FindingDTO: Encodable {
    let severity: String
    let key: String
    let title: String
    let detail: String
    let hops: [Int]

    init(_ f: Finding) {
        severity = ["ok", "info", "warning", "critical"][f.severity.rawValue]
        key = f.key; title = f.title; detail = f.detail; hops = f.hops
    }
}

struct HopDTO: Encodable {
    let ttl: Int
    let address: String?
    let hostname: String?
    let otherAddresses: [String]
    let isDestination: Bool
    let isPrivateAddress: Bool
    let stats: StatsDTO

    init(_ h: Hop, names: [String: String]) {
        ttl = h.ttl
        address = h.primaryAddress
        hostname = h.primaryAddress.flatMap { ip in names[ip].flatMap { $0 == ip ? nil : $0 } }
        otherAddresses = Array(h.significantResponders.dropFirst())
        isDestination = h.isDestination
        isPrivateAddress = h.primaryAddress.map(Resolver.isPrivate) ?? false
        stats = StatsDTO(h.stats)
    }
}

struct PathDTO: Encodable {
    let target: String
    let ipVersion: String
    let twinOf: String?
    let address: String?
    let destinationReached: Bool
    let hopCount: Int?
    let tunnelInterface: String?
    let traceCycles: Int
    let probesPerHopWindow: Int
    let speedTestRunning: Bool
    let findings: [FindingDTO]
    let hops: [HopDTO]
}

struct TargetStatusDTO: Encodable {
    let host: String
    let ipVersion: String
    /// Set on automatic IPv6 twins: the configured target this mirrors.
    let twinOf: String?
    let address: String?
    let health: String
    let tunnelInterface: String?
    let hopCount: Int?
    let last60s: StatsDTO
    let last5m: StatsDTO
    let findings: [FindingDTO]
}

struct StatusDTO: Encodable {
    let generatedAt: Date
    let overallHealth: String
    let ipv6Available: Bool
    let speedTestRunning: Bool
    let alertsPausedForSpeedTest: Bool
    let targets: [TargetStatusDTO]
    let lastSpeedTest: ThroughputResult?
    let recentEvents: [NetEvent]
    let thresholds: [String: Double]
}

struct HistoryPointDTO: Encodable {
    let t: Date
    let avgMs: Double?
    let maxMs: Double?
    let lossPercent: Double

    init(_ p: ChartPoint) {
        t = p.t
        avgMs = r1(p.avg)
        maxMs = r1(p.max)
        lossPercent = r1(p.lossPercent) ?? 0
    }
}

struct HistoryDTO: Encodable {
    let target: String
    let range: String
    let bucketSeconds: Int
    let summary: StatsDTO
    /// The worst buckets at the range's finest resolution, so "when was it bad?" needs no scan.
    let worstPeriods: WorstPeriodsDTO
    let points: [HistoryPointDTO]
}

struct WorstPeriodsDTO: Encodable {
    let bucketSeconds: Int
    let highestAvgLatency: [HistoryPointDTO]
    let highestLoss: [HistoryPointDTO]
    let biggestSpikes: [HistoryPointDTO]
}

struct TraceDTO: Encodable {
    let host: String
    let address: String?
    let cycles: Int
    let durationSeconds: Double
    let destinationReached: Bool
    let tunnelInterface: String?
    let speedTestWasRunning: Bool
    let findings: [FindingDTO]
    let hops: [HopDTO]
}

extension Health {
    var apiName: String { ["unknown", "ok", "degraded", "down"][rawValue] }
}

// MARK: Routing

@MainActor
enum APIRoutes {
    static func handle(_ req: HTTPRequest) async -> HTTPResponse {
        let model = AppModel.shared
        let body = (try? JSONSerialization.jsonObject(with: req.body.isEmpty ? Data("{}".utf8) : req.body)) as? [String: Any] ?? [:]

        switch (req.method, req.path) {
        case ("GET", "/status"):
            return .json(status(model))

        case ("GET", "/path"):
            let monitors = select(model, req.query["target"])
            guard !monitors.isEmpty else { return .error(404, unknownTarget(model, req.query["target"])) }
            return .json(monitors.map { path($0, model) })

        case ("GET", "/history"):
            guard let range = TimeRange(rawValue: req.query["range"] ?? "1h") else {
                return .error(400, "range must be one of \(TimeRange.allCases.map(\.rawValue))")
            }
            let monitors = select(model, req.query["target"])
            guard !monitors.isEmpty else { return .error(404, unknownTarget(model, req.query["target"])) }
            // Keep responses small enough for an MCP client: coarsen buckets to at most `points`.
            let maxPoints = min(500, max(10, Int(req.query["points"] ?? "") ?? 60))
            let bucket = max(range.bucket, (range.seconds / Double(maxPoints)).rounded(.up))
            return .json(monitors.map { m in
                let fine = model.chartPoints(for: m, range: range)
                let coarse = bucket == range.bucket ? fine : model.chartPoints(for: m, range: range, bucket: bucket)
                func top(_ value: (ChartPoint) -> Double?) -> [HistoryPointDTO] {
                    fine.filter { (value($0) ?? 0) > 0 }.sorted { value($0) ?? 0 > value($1) ?? 0 }.prefix(3).map(HistoryPointDTO.init)
                }
                return HistoryDTO(target: m.host, range: range.rawValue, bucketSeconds: Int(bucket),
                                  summary: StatsDTO(model.rangeStats(for: m, range: range)),
                                  worstPeriods: WorstPeriodsDTO(bucketSeconds: Int(range.bucket),
                                                                highestAvgLatency: top(\.avg),
                                                                highestLoss: top(\.lossPercent),
                                                                biggestSpikes: top(\.max)),
                                  points: coarse.map(HistoryPointDTO.init))
            })

        case ("GET", "/events"):
            let limit = Int(req.query["limit"] ?? "") ?? 50
            var events = model.events
            if let minutes = Double(req.query["since_minutes"] ?? "") {
                let cutoff = Date().addingTimeInterval(-minutes * 60)
                events = events.filter { $0.date >= cutoff }
            }
            return .json(Array(events.suffix(limit).reversed()))

        case ("GET", "/throughput"):
            let limit = Int(req.query["limit"] ?? "") ?? 20
            return .json(Array(model.throughputHistory.suffix(limit).reversed()))

        case ("POST", "/speedtest"):
            let wait = body["wait"] as? Bool ?? true
            if !wait {
                let alreadyRunning = model.speedTestRunning
                model.runSpeedTest()
                return .json(["started": !alreadyRunning, "alreadyRunning": alreadyRunning])
            }
            switch await model.runSpeedTestAndWait() {
            case .success(let r): return .json(r)
            case .failure(let e): return .error(500, "speed test failed: \(e.localizedDescription)")
            }

        case ("POST", "/trace"):
            guard let host = (body["host"] as? String)?.trimmingCharacters(in: .whitespaces), !host.isEmpty else {
                return .error(400, "body must include \"host\"")
            }
            let cycles = min(60, max(3, body["cycles"] as? Int ?? 15))
            let maxHops = min(64, max(1, body["max_hops"] as? Int ?? 30))
            guard let result = await AdHocTrace.run(host: host, cycles: cycles, maxHops: maxHops) else {
                return .error(400, "could not resolve \(host) to an IP address")
            }
            return .json(result)

        case ("POST", "/reset"):
            let monitors = select(model, body["target"] as? String)
            guard !monitors.isEmpty else { return .error(404, unknownTarget(model, body["target"] as? String)) }
            monitors.forEach { $0.resetPathStats() }
            return .json(["reset": monitors.map(\.host)])

        case ("POST", "/open"):
            let name = (body["section"] as? String ?? "overview").lowercased()
            guard let section = SidebarItem.allCases.first(where: { $0.rawValue.lowercased() == name }) else {
                return .error(400, "section must be one of \(SidebarItem.allCases.map { $0.rawValue.lowercased() })")
            }
            guard model.showWindow(section) else { return .error(503, "window not ready yet; try again in a moment") }
            return .json(["opened": name])

        case ("GET", "/settings"):
            return .json(SettingsAPI.current())

        case ("POST", "/settings"):
            switch SettingsAPI.apply(body) {
            case .success(let changed):
                if changed.contains("targets") { model.applyTargets() }
                return .json(SettingsAPI.current())
            case .failure(let e):
                return .error(400, e.message)
            }

        default:
            return .error(404, "no route \(req.method) \(req.path)")
        }
    }

    private static func select(_ model: AppModel, _ target: String?) -> [TargetMonitor] {
        guard let target, !target.isEmpty else { return model.monitors }
        return model.monitors.filter { $0.host == target || $0.address == target }
    }

    private static func unknownTarget(_ model: AppModel, _ target: String?) -> String {
        "unknown target \(target ?? "") (monitored: \(model.monitors.map(\.host).joined(separator: ", ")))"
    }

    static func status(_ model: AppModel) -> StatusDTO {
        StatusDTO(
            generatedAt: Date(),
            overallHealth: model.overallHealth.apiName,
            ipv6Available: model.ipv6Available,
            speedTestRunning: model.speedTestRunning,
            alertsPausedForSpeedTest: model.inSpeedTestQuietPeriod,
            targets: model.monitors.map { m in
                TargetStatusDTO(host: m.host, ipVersion: m.family.label, twinOf: m.twinOf, address: m.address, health: m.health.apiName,
                                tunnelInterface: m.tunnelInterface, hopCount: m.destinationTTL,
                                last60s: StatsDTO(m.stats(lastSeconds: 60)), last5m: StatsDTO(m.stats(lastSeconds: 300)),
                                findings: m.findings.filter { $0.severity >= .warning || $0.key == "healthy" || $0.key == "tunnel" }
                                    .map(FindingDTO.init))
            },
            lastSpeedTest: model.lastThroughput,
            recentEvents: Array(model.events.suffix(5).reversed()),
            thresholds: ["lossPercent": Prefs.lossAlertPercent, "latencyMs": Prefs.latencyAlertMs, "jitterMs": Prefs.jitterAlertMs])
    }

    private static func path(_ m: TargetMonitor, _ model: AppModel) -> PathDTO {
        PathDTO(target: m.host, ipVersion: m.family.label, twinOf: m.twinOf, address: m.address, destinationReached: m.destinationTTL != nil,
                hopCount: m.destinationTTL, tunnelInterface: m.tunnelInterface, traceCycles: m.traceCycles,
                probesPerHopWindow: Hop.window, speedTestRunning: model.speedTestRunning,
                findings: m.findings.map(FindingDTO.init),
                hops: m.hops.map { HopDTO($0, names: m.hostnames) })
    }
}

// MARK: Ad-hoc trace

enum AdHocTrace {
    @MainActor
    static func run(host: String, cycles: Int, maxHops: Int) async -> TraceDTO? {
        let started = Date()
        // IPv4 unless the host is an IPv6 address or has no IPv4 address.
        guard let address = await Task.detached(operation: {
            Resolver.address(for: host, family: .v4) ?? Resolver.address(for: host, family: .v6)
        }).value else { return nil }
        let speedTestWasRunning = AppModel.shared.speedTestRunning
        var tracer = PathTracer(maxHops: maxHops)
        for i in 0..<cycles {
            let cycleStart = Date()
            tracer.apply(await PathTracer.probeCycle(address, limit: tracer.probeLimit))
            if i < cycles - 1 {
                try? await Task.sleep(for: .seconds(max(0.1, 1 - Date().timeIntervalSince(cycleStart))))
            }
        }
        let hops = tracer.hops
        var names: [String: String] = [:]
        for ip in Set(hops.flatMap { $0.responders.keys }) { names[ip] = await Resolver.name(for: ip) }
        let tunnel = Resolver.tunnelInterface(toward: address)
        let findings = PathDiagnosis.diagnose(target: host, hops: hops, reached: tracer.destinationTTL != nil,
                                              names: names, tunnel: tunnel, minSamples: min(PathDiagnosis.minSamples, cycles))
        return TraceDTO(host: host, address: address, cycles: cycles,
                        durationSeconds: r1(Date().timeIntervalSince(started)) ?? 0,
                        destinationReached: tracer.destinationTTL != nil, tunnelInterface: tunnel,
                        speedTestWasRunning: speedTestWasRunning,
                        findings: findings.map(FindingDTO.init), hops: hops.map { HopDTO($0, names: names) })
    }
}

// MARK: Settings

enum SettingsAPI {
    struct Failure: Error { let message: String }

    private enum Kind { case double(ClosedRange<Double>), int(ClosedRange<Int>), bool, targets }

    /// API name → (UserDefaults key, type and allowed range).
    private static let specs: [String: (key: String, kind: Kind)] = [
        "targets": (Prefs.Key.targets, .targets),
        "ping_interval_seconds": (Prefs.Key.pingInterval, .double(0.5...10)),
        "trace_interval_seconds": (Prefs.Key.traceInterval, .double(1...30)),
        "max_hops": (Prefs.Key.maxHops, .int(5...64)),
        "loss_alert_percent": (Prefs.Key.lossAlertPercent, .double(1...50)),
        "latency_alert_ms": (Prefs.Key.latencyAlertMs, .double(20...1000)),
        "jitter_alert_ms": (Prefs.Key.jitterAlertMs, .double(5...200)),
        "notifications_enabled": (Prefs.Key.notificationsEnabled, .bool),
        "notify_path_findings": (Prefs.Key.notifyPathFindings, .bool),
        "auto_speed_test": (Prefs.Key.autoSpeedTest, .bool),
        "speed_test_cooldown_minutes": (Prefs.Key.speedTestCooldownMinutes, .double(15...1440)),
        "min_download_mbps": (Prefs.Key.minDownloadMbps, .double(0...10_000)),
        "history_days": (Prefs.Key.historyDays, .int(1...90)),
    ]

    static var names: [String] { specs.keys.sorted() }

    static func current() -> [String: AnyEncodable] {
        var out: [String: AnyEncodable] = [:]
        let d = UserDefaults.standard
        for (name, spec) in specs {
            switch spec.kind {
            case .double: out[name] = AnyEncodable(d.double(forKey: spec.key))
            case .int: out[name] = AnyEncodable(d.integer(forKey: spec.key))
            case .bool: out[name] = AnyEncodable(d.bool(forKey: spec.key))
            case .targets: out[name] = AnyEncodable(Prefs.targets)
            }
        }
        return out
    }

    /// Validates every field first, then writes; returns the names that changed.
    static func apply(_ body: [String: Any]) -> Result<[String], Failure> {
        var writes: [(String, String, Any)] = []
        for (name, value) in body {
            guard let spec = specs[name] else {
                return .failure(Failure(message: "unknown setting \(name); valid: \(names.joined(separator: ", "))"))
            }
            switch spec.kind {
            case .double(let range):
                guard let v = (value as? NSNumber)?.doubleValue, range.contains(v) else {
                    return .failure(Failure(message: "\(name) must be a number in \(range)"))
                }
                writes.append((name, spec.key, v))
            case .int(let range):
                guard let v = (value as? NSNumber)?.intValue, range.contains(v) else {
                    return .failure(Failure(message: "\(name) must be an integer in \(range)"))
                }
                writes.append((name, spec.key, v))
            case .bool:
                guard let v = value as? Bool else { return .failure(Failure(message: "\(name) must be true or false")) }
                writes.append((name, spec.key, v))
            case .targets:
                let list = (value as? [String]) ?? (value as? String)?.split(separator: ",").map(String.init) ?? []
                let cleaned = list.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                guard !cleaned.isEmpty else { return .failure(Failure(message: "targets must be a non-empty list of hosts")) }
                writes.append((name, spec.key, cleaned.joined(separator: ", ")))
            }
        }
        for (_, key, v) in writes { UserDefaults.standard.set(v, forKey: key) }
        return .success(writes.map(\.0))
    }
}

struct AnyEncodable: Encodable {
    private let encodeFn: (Encoder) throws -> Void
    init(_ value: some Encodable) { encodeFn = value.encode }
    func encode(to encoder: Encoder) throws { try encodeFn(encoder) }
}
