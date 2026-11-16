import Foundation
import Observation

enum Health: Int, Comparable {
    case unknown, ok, degraded, down
    static func < (a: Health, b: Health) -> Bool { a.rawValue < b.rawValue }
}

/// One router (or the destination) on the path, at a given TTL.
struct Hop: Identifiable {
    static let window = 100

    let ttl: Int
    /// Responders seen at this TTL and how often; more than one means ECMP / load balancing.
    var responders: [String: Int] = [:]
    /// Most recent `window` probe results, nil = no answer.
    var results: [Double?] = []
    var isDestination = false
    /// Parallel to `results`: whether that answer was an echo reply from the destination.
    private(set) var fromEcho: [Bool] = []

    var id: Int { ttl }
    var primaryAddress: String? { responders.max { $0.value < $1.value }?.key }
    /// Responders seen on at least 10% of answers; filters one-off oddities out of ECMP display.
    var significantResponders: [String] {
        let total = responders.values.reduce(0, +)
        return responders.filter { $0.value * 10 >= total }.sorted { $0.value > $1.value }.map(\.key)
    }
    var stats: ProbeStats { ProbeStats(results) }

    mutating func record(_ r: ProbeResult) {
        results.append(r.answered ? r.rtt : nil)
        fromEcho.append(r.kind == .echoReply)
        if results.count > Self.window {
            results.removeFirst(results.count - Self.window)
            fromEcho.removeFirst(fromEcho.count - Self.window)
        }
        if let who = r.responder { responders[who, default: 0] += 1 }
    }

    /// Drops answers that were echo replies from `destination`. Used for hops short of the
    /// destination, where such a reply is impossible (the packet should have expired).
    mutating func discardEchoReplies(from destination: String?) {
        let drop = fromEcho.filter { $0 }.count
        guard drop > 0 else { return }
        results = zip(results, fromEcho).filter { !$0.1 }.map(\.0)
        fromEcho = fromEcho.filter { !$0 }
        if let destination, let n = responders[destination] {
            responders[destination] = n > drop ? n - drop : nil
        }
    }
}

/// Monitors one target: a once-a-second latency ping plus a continuous mtr-style trace.
@MainActor
@Observable
final class TargetMonitor: Identifiable {
    nonisolated static let sampleRetention: TimeInterval = 3600

    /// The target as shown and keyed (rollups, alerts, API).
    let host: String
    /// What to resolve: usually `host`; for an IPv6 twin of a hostname, the hostname itself.
    let lookup: String
    let family: IPFamily
    /// For an automatic IPv6 twin, the configured target it mirrors.
    let twinOf: String?
    private(set) var address: String?
    private(set) var resolveFailed = false
    /// Last hour of latency samples, ordered by send time.
    private(set) var samples: [LatencySample] = []
    private(set) var tracer = PathTracer(maxHops: Prefs.maxHops)
    private(set) var hostnames: [String: String] = [:]
    private(set) var findings: [Finding] = []
    /// Outgoing interface when traffic to this target goes through a VPN tunnel (e.g. "utun4").
    private(set) var tunnelInterface: String?

    @ObservationIgnored var onRollup: ((MinuteRollup) -> Void)?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []

    nonisolated var id: String { host }

    init(host: String, lookup: String? = nil, family: IPFamily = .v4, twinOf: String? = nil) {
        self.host = host
        self.lookup = lookup ?? host
        self.family = family
        self.twinOf = twinOf
    }

    // MARK: Lifecycle

    func start() {
        stop()
        tasks.append(Task { [weak self] in
            guard let self else { return }
            let (lookup, family) = (self.lookup, self.family)
            let resolved = await Task.detached { Resolver.address(for: lookup, family: family) }.value
            if Task.isCancelled { return }
            guard let resolved else { self.resolveFailed = true; return }
            self.address = resolved
            self.tasks.append(Task { await self.pingLoop(resolved) })
            self.tasks.append(Task { await self.traceLoop(resolved) })
            self.tasks.append(Task { await self.rollupLoop() })
        })
    }

    func stop() {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
    }

    func resetPathStats() {
        tracer.reset()
        findings = []
    }

    // MARK: Derived state

    var hops: [Hop] { tracer.hops }
    var destinationTTL: Int? { tracer.destinationTTL }
    var traceCycles: Int { tracer.cycles }

    func stats(lastSeconds seconds: TimeInterval) -> ProbeStats {
        let cutoff = Date().addingTimeInterval(-seconds)
        // Skip the newest couple of seconds: those probes may still be in flight.
        let settled = Date().addingTimeInterval(-2.5)
        return ProbeStats(samples.lazy.filter { $0.t >= cutoff && $0.t <= settled }.map(\.rtt))
    }

    var health: Health {
        let s = stats(lastSeconds: 30)
        guard s.sent >= 5 else { return resolveFailed ? .down : .unknown }
        if s.received == 0 { return .down }
        if s.lossPercent >= Prefs.lossAlertPercent || (s.avg ?? 0) >= Prefs.latencyAlertMs { return .degraded }
        return .ok
    }

    var worstFinding: Finding? { findings.max { $0.severity < $1.severity } }

    func displayName(for ip: String?) -> String {
        guard let ip else { return "???" }
        return hostnames[ip] ?? ip
    }

    // MARK: Loops

    private func pingLoop(_ address: String) async {
        while !Task.isCancelled {
            let sentAt = Date()
            Task { [weak self] in
                let r = await Pinger.shared.probe(address, ttl: 64, timeout: 2)
                self?.recordSample(LatencySample(t: sentAt, rtt: r.kind == .echoReply ? r.rtt : nil))
            }
            try? await Task.sleep(for: .seconds(Prefs.pingInterval))
        }
    }

    private func recordSample(_ sample: LatencySample) {
        // Timeouts land ~2s late, so insert in send order rather than appending.
        var i = samples.endIndex
        while i > samples.startIndex, samples[i - 1].t > sample.t { i -= 1 }
        samples.insert(sample, at: i)
        let cutoff = Date().addingTimeInterval(-Self.sampleRetention)
        if let first = samples.first, first.t < cutoff {
            samples.removeAll { $0.t < cutoff }
        }
    }

    private func traceLoop(_ address: String) async {
        while !Task.isCancelled {
            let started = Date()
            tracer.maxHops = Prefs.maxHops
            if traceCycles % 15 == 0 { tunnelInterface = Resolver.tunnelInterface(toward: address) }
            let results = await PathTracer.probeCycle(address, limit: tracer.probeLimit)
            // Hop stats gathered while a speed test fills the link would all look bad.
            if !AppModel.shared.inSpeedTestQuietPeriod { applyTrace(results) }
            let elapsed = Date().timeIntervalSince(started)
            try? await Task.sleep(for: .seconds(max(0.1, Prefs.traceInterval - elapsed)))
        }
    }

    private func applyTrace(_ results: [(Int, ProbeResult)]) {
        tracer.apply(results)
        for (_, r) in results {
            if let ip = r.responder, hostnames[ip] == nil {
                hostnames[ip] = Resolver.cachedName(for: ip) ?? ip
                Task { [weak self] in
                    let name = await Resolver.name(for: ip)
                    self?.hostnames[ip] = name
                }
            }
        }
        findings = PathDiagnosis.diagnose(target: host, hops: hops, reached: destinationTTL != nil,
                                          names: hostnames, tunnel: tunnelInterface)
    }

    /// Rolls up each completed minute of samples a few seconds after it ends.
    private func rollupLoop() async {
        while !Task.isCancelled {
            let now = Date().timeIntervalSince1970
            let nextMinute = (now / 60).rounded(.down) * 60 + 60
            try? await Task.sleep(for: .seconds(nextMinute - now + 3))
            if Task.isCancelled { return }
            let end = Date(timeIntervalSince1970: nextMinute)
            let start = end.addingTimeInterval(-60)
            let window = samples.filter { $0.t >= start && $0.t < end }
            guard !window.isEmpty else { continue }
            let s = ProbeStats(window.map(\.rtt))
            onRollup?(MinuteRollup(target: host, start: start, sent: s.sent, received: s.received,
                                   avg: s.avg, min: s.best, max: s.worst, jitter: s.jitter))
        }
    }
}
