import Foundation

/// mtr-style hop state for one destination: which TTL is the destination, and a rolling
/// window of probe results per hop. Shared by the continuous monitors and ad-hoc traces.
struct PathTracer {
    private static let echoWindow = 5
    private static let echoConfirmations = 3

    var maxHops: Int
    private(set) var hopsByTTL: [Int: Hop] = [:]
    private(set) var destinationTTL: Int?
    private(set) var cycles = 0
    private var echoHistory: [Int: [Bool]] = [:]

    init(maxHops: Int) {
        self.maxHops = maxHops
    }

    /// TTLs to probe next cycle: a couple past the destination so a longer route is noticed.
    var probeLimit: Int { destinationTTL.map { min(maxHops, $0 + 2) } ?? maxHops }

    /// Hops to display: up to the destination, or one past the furthest responder.
    var hops: [Hop] {
        let limit: Int
        if let destinationTTL {
            limit = destinationTTL
        } else {
            let furthest = hopsByTTL.values.filter { $0.stats.received > 0 }.map(\.ttl).max() ?? 0
            limit = min(maxHops, furthest + 1)
        }
        guard limit > 0 else { return [] }
        return (1...limit).map { hopsByTTL[$0] ?? Hop(ttl: $0) }
    }

    mutating func reset() {
        hopsByTTL.removeAll()
        echoHistory.removeAll()
        destinationTTL = nil
        cycles = 0
    }

    mutating func apply(_ results: [(Int, ProbeResult)]) {
        // A TTL only counts as the destination once it has answered with echo replies in
        // most recent cycles. One-off echo replies at a low TTL happen (VPN clients and
        // tunnels do odd things with TTL), and trusting one would collapse the path.
        for (ttl, r) in results {
            var history = echoHistory[ttl, default: []]
            history.append(r.kind == .echoReply)
            if history.count > Self.echoWindow { history.removeFirst() }
            echoHistory[ttl] = history
        }
        let confirmed = echoHistory.keys.sorted().first { ttl in
            (echoHistory[ttl] ?? []).filter { $0 }.count >= Self.echoConfirmations
        }
        if confirmed != destinationTTL {
            destinationTTL = confirmed
            if let confirmed {
                hopsByTTL = hopsByTTL.filter { $0.key <= confirmed }
                // Tunnels sometimes answer every TTL with an echo reply on the first burst.
                // Short of the destination that's impossible, so scrub those answers.
                let destAddress = results.first { $0.0 == confirmed && $0.1.kind == .echoReply }?.1.responder
                for ttl in hopsByTTL.keys where ttl < confirmed {
                    hopsByTTL[ttl]?.discardEchoReplies(from: destAddress)
                }
            }
        }

        let limit = destinationTTL ?? maxHops
        for (ttl, r) in results where ttl <= limit {
            if let dest = destinationTTL, ttl < dest, r.kind == .echoReply { continue }
            var hop = hopsByTTL[ttl] ?? Hop(ttl: ttl)
            hop.isDestination = ttl == destinationTTL
            hop.record(r)
            hopsByTTL[ttl] = hop
        }
        cycles += 1
    }

    /// Sends one probe per TTL in `1...limit` concurrently and returns results by TTL.
    static func probeCycle(_ address: String, limit: Int) async -> [(Int, ProbeResult)] {
        await withTaskGroup(of: (Int, ProbeResult).self) { group in
            for ttl in 1...max(1, limit) {
                group.addTask { (ttl, await Pinger.shared.probe(address, ttl: ttl, timeout: 2)) }
            }
            var all: [(Int, ProbeResult)] = []
            for await r in group { all.append(r) }
            return all.sorted { $0.0 < $1.0 }
        }
    }
}
