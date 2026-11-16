import Foundation

struct Finding: Identifiable, Hashable {
    enum Severity: Int, Comparable {
        case ok, info, warning, critical
        static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    }

    let severity: Severity
    /// Stable identity for de-duplicating notifications, e.g. "loss@3".
    let key: String
    let title: String
    let detail: String
    var hops: [Int] = []

    var id: String { key }
}

/// Reads an mtr-style hop table the way an experienced operator would.
///
/// The core rule: a problem is only real if it **carries forward**. Routers often
/// rate-limit or deprioritise the ICMP replies they generate themselves, so a hop showing
/// loss or high latency while later hops look fine is the router being busy answering us,
/// not dropping or delaying traffic it forwards.
enum PathDiagnosis {
    static let minSamples = 10

    static func diagnose(target: String, hops: [Hop], reached: Bool, names: [String: String],
                         tunnel: String? = nil, minSamples: Int = minSamples) -> [Finding] {
        guard let last = hops.last, last.stats.sent >= minSamples else {
            return [Finding(severity: .info, key: "collecting", title: "Collecting path data…",
                            detail: "Need at least \(minSamples) probes per hop before diagnosing.")]
        }

        func label(_ hop: Hop) -> String {
            let ip = hop.primaryAddress ?? "?"
            let name = names[ip].flatMap { $0 == ip ? nil : $0 }
            return "hop \(hop.ttl) (\(name.map { "\($0), \(ip)" } ?? ip))"
        }
        let firstResponding = hops.first { $0.stats.received >= 5 }?.ttl
        func whereIs(_ hop: Hop) -> String {
            if let tunnel, hop.ttl == firstResponding {
                return "Traffic goes through your VPN (\(tunnel)), and this is the first hop visible inside the tunnel. Its numbers include the whole encrypted path to the VPN server, so the problem may be your local link, your ISP, or the VPN provider. Disconnect the VPN and compare."
            }
            if hop.ttl == 1 { return "This is your first hop, which is your own router or Wi-Fi. Check signal strength, cabling, or reboot the router." }
            if let ip = hop.primaryAddress, Resolver.isPrivate(ip) {
                return "This address is private (LAN, CGNAT or VPN), so the fault is in your local or ISP access network."
            }
            if hop.ttl <= 3 { return "This is close to you, most likely your ISP's access network." }
            return "This is beyond your ISP's edge, so it's likely upstream congestion. You can't fix it, but you can report it to your ISP."
        }

        var findings: [Finding] = []
        let responding = hops.filter { $0.stats.received > 0 }
        // Latency and jitter need enough replies to mean anything; a hop that answered once
        // in a hundred probes would otherwise produce a bogus "jump".
        let measurable = responding.filter { $0.stats.received >= 5 || $0.isDestination }

        guard reached, let dest = responding.last, dest.isDestination else {
            let lastGood = responding.last
            let close = (lastGood?.ttl ?? 0) <= 2
            findings.append(Finding(
                severity: close ? .critical : .warning, key: "unreachable",
                title: "\(target) is not answering",
                detail: lastGood.map { "Probes get as far as \(label($0)) and stop there. \(whereIs($0))" }
                    ?? "No hop is answering at all. You are probably offline.",
                hops: lastGood.map { [$0.ttl] } ?? []))
            return findings
        }

        let destStats = dest.stats
        var benign: [String] = []

        // Packet loss that carries through to the destination.
        let destLoss = destStats.lossPercent
        if destLoss >= 2 {
            let threshold = max(1, destLoss * 0.5)
            let originIndex = responding.indices.first { i in
                responding[i...].allSatisfy { $0.stats.lossPercent >= threshold }
            } ?? responding.endIndex - 1
            let origin = responding[originIndex]
            let severe = destLoss >= Prefs.lossAlertPercent
            if origin.isDestination {
                findings.append(Finding(
                    severity: severe ? .warning : .info, key: "loss@dest",
                    title: String(format: "%.0f%% loss at the destination only", destLoss),
                    detail: "Every hop before \(target) is clean. Either the destination is rate-limiting ICMP or the loss is on its final link.",
                    hops: [dest.ttl]))
            } else {
                findings.append(Finding(
                    severity: severe ? .critical : .warning, key: "loss@\(origin.ttl)",
                    title: "Packet loss starts at hop \(origin.ttl)",
                    detail: String(format: "%.0f%% loss begins at %@ and continues to the destination (%.0f%%). Earlier hops are clean. ",
                                   origin.stats.lossPercent, label(origin), destLoss) + whereIs(origin),
                    hops: Array(origin.ttl...dest.ttl)))
            }
        }

        // Latency: find the biggest step up that persists to the destination.
        if let destAvg = destStats.avg {
            var prevAvg = 0.0
            var biggest: (hop: Hop, delta: Double, before: Double)?
            for hop in measurable {
                guard let avg = hop.stats.avg else { continue }
                let delta = avg - prevAvg
                let persists = destAvg >= prevAvg + delta * 0.7
                if persists, delta >= max(25, prevAvg * 0.5), delta > (biggest?.delta ?? 0) {
                    biggest = (hop, delta, prevAvg)
                }
                if !hop.isDestination, avg > destAvg + 50 {
                    benign.append(String(format: "hop %d: slow replies (%.0f ms) that don't carry forward", hop.ttl, avg))
                }
                prevAvg = min(avg, destAvg) // a non-persistent spike shouldn't hide the next real jump
            }
            // Through a VPN the first visible hop carries the whole tunnel; the tunnel finding covers it.
            if let b = biggest, !(tunnel != nil && b.hop.ttl == measurable.first?.ttl) {
                let high = destAvg >= Prefs.latencyAlertMs
                findings.append(Finding(
                    severity: high ? .warning : .info, key: "latency@\(b.hop.ttl)",
                    title: String(format: "Latency jumps +%.0f ms at hop %d", b.delta, b.hop.ttl),
                    detail: String(format: "Latency rises from %.0f ms to %.0f ms at %@ and stays high through to the destination (%.0f ms). ",
                                   b.before, b.before + b.delta, label(b.hop), destAvg)
                        + (high ? whereIs(b.hop) : "Long-distance links add latency legitimately, so this is only a concern if it's new."),
                    hops: [b.hop.ttl]))
            }
        }

        // First hop should be a few ms. Anything slower points at Wi-Fi or a busy router.
        // (Not meaningful through a VPN, where "hop 1" is the far side of the tunnel.)
        if tunnel == nil, let first = measurable.first, first.ttl == 1, let avg = first.stats.avg, let worst = first.stats.worst,
           avg > 15 || worst > 150 {
            findings.append(Finding(
                severity: .warning, key: "lan-latency",
                title: String(format: "Local network is slow (%.0f ms avg, %.0f ms worst)", avg, worst),
                detail: "Your router should answer in under ~5 ms. Spikes this high usually mean Wi-Fi interference or a weak signal, or bufferbloat from a saturated uplink.",
                hops: [1]))
        }

        // Jitter that carries forward.
        if let destJitter = destStats.jitter, destJitter >= Prefs.jitterAlertMs {
            let threshold = destJitter * 0.6
            let origin = measurable.indices.first { i in
                measurable[i...].allSatisfy { ($0.stats.jitter ?? 0) >= threshold }
            }.map { measurable[$0] } ?? dest
            findings.append(Finding(
                severity: .warning, key: "jitter@\(origin.ttl)",
                title: String(format: "High jitter (%.0f ms) from hop %d", destJitter, origin.ttl),
                detail: "Latency becomes erratic at \(label(origin)), which hurts calls and gaming. " + whereIs(origin),
                hops: [origin.ttl]))
        }

        // Loss that does NOT carry forward is ICMP rate limiting.
        for (i, hop) in responding.enumerated() where !hop.isDestination {
            let loss = hop.stats.lossPercent
            guard loss >= 10 else { continue }
            let later = responding[(i + 1)...]
            if later.contains(where: { $0.stats.lossPercent < loss * 0.5 }) {
                benign.append(String(format: "hop %d: %.0f%% loss that doesn't carry forward", hop.ttl, loss))
            }
        }
        let silent = hops.filter { $0.stats.received == 0 && $0.stats.sent >= minSamples && !$0.isDestination }
        if !silent.isEmpty {
            benign.append("hop \(silent.map { String($0.ttl) }.joined(separator: ", ")): never answers probes (filtered)")
        }
        if !benign.isEmpty {
            findings.append(Finding(
                severity: .info, key: "benign",
                title: "Harmless anomalies",
                detail: "Routers deprioritise the ICMP replies they generate themselves, so these don't affect real traffic:\n• "
                    + benign.joined(separator: "\n• ")))
        }

        if let tunnel {
            findings.append(Finding(
                severity: .info, key: "tunnel", title: "Measuring through a VPN (\(tunnel))",
                detail: "Hops are traced inside the tunnel. Your real local network and ISP hops are hidden, and every visible hop includes the latency to the VPN server."))
        }

        if !findings.contains(where: { $0.severity >= .warning }) {
            findings.append(Finding(
                severity: .ok, key: "healthy", title: "Path looks healthy",
                detail: String(format: "%d hops to %@: %.1f ms avg, %.0f%% loss, %.1f ms jitter.",
                               dest.ttl, target, destStats.avg ?? 0, destLoss, destStats.jitter ?? 0)))
        }
        return findings.sorted { $0.severity > $1.severity }
    }
}
