import XCTest
@testable import NetMon

final class PathDiagnosisTests: XCTestCase {
    override func setUp() {
        Prefs.register()
    }

    /// Builds a hop with `n` probes at `rtt` ms, of which `lossPercent` are lost.
    private func hop(_ ttl: Int, _ ip: String, rtt: Double, loss: Double = 0, jitter: Double = 0,
                     dest: Bool = false, n: Int = 100) -> Hop {
        var h = Hop(ttl: ttl)
        let lost = Int((Double(n) * loss / 100).rounded())
        h.results = (0..<n).map { i in i < lost ? nil : rtt + (i.isMultiple(of: 2) ? jitter : -jitter) / 2 }
        h.responders = [ip: n - lost]
        h.isDestination = dest
        return h
    }

    private func diagnose(_ hops: [Hop], reached: Bool = true) -> [Finding] {
        PathDiagnosis.diagnose(target: "1.1.1.1", hops: hops, reached: reached, names: [:])
    }

    func testHealthyPath() {
        let f = diagnose([hop(1, "192.168.1.1", rtt: 2), hop(2, "10.0.0.1", rtt: 8), hop(3, "1.1.1.1", rtt: 12, dest: true)])
        XCTAssertEqual(f.first?.key, "healthy")
    }

    func testIntermediateLossThatDoesNotCarryForwardIsBenign() {
        let f = diagnose([hop(1, "192.168.1.1", rtt: 2), hop(2, "203.0.113.1", rtt: 9, loss: 60),
                          hop(3, "1.1.1.1", rtt: 12, dest: true)])
        XCTAssertFalse(f.contains { $0.severity >= .warning })
        XCTAssertTrue(f.contains { $0.key == "benign" && $0.detail.contains("hop 2") })
    }

    func testLossCarryingToDestinationIsLocatedAtOrigin() {
        let f = diagnose([hop(1, "192.168.1.1", rtt: 2), hop(2, "203.0.113.1", rtt: 9),
                          hop(3, "198.51.100.7", rtt: 11, loss: 12), hop(4, "1.1.1.1", rtt: 13, loss: 10, dest: true)])
        let loss = f.first { $0.key.hasPrefix("loss@") }
        XCTAssertEqual(loss?.key, "loss@3")
        XCTAssertEqual(loss?.severity, .critical)
    }

    func testFirstHopLossBlamesLocalNetwork() {
        let f = diagnose([hop(1, "192.168.1.1", rtt: 3, loss: 8), hop(2, "203.0.113.1", rtt: 9, loss: 8),
                          hop(3, "1.1.1.1", rtt: 12, loss: 9, dest: true)])
        let loss = f.first { $0.key.hasPrefix("loss@") }
        XCTAssertEqual(loss?.key, "loss@1")
        XCTAssertTrue(loss?.detail.contains("your own router") ?? false)
    }

    func testPersistentLatencyJumpIsFoundButSpikeIsBenign() {
        let f = diagnose([hop(1, "192.168.1.1", rtt: 2), hop(2, "203.0.113.1", rtt: 300),
                          hop(3, "198.51.100.7", rtt: 10), hop(4, "198.51.100.9", rtt: 190),
                          hop(5, "1.1.1.1", rtt: 195, dest: true)])
        XCTAssertNotNil(f.first { $0.key == "latency@4" && $0.severity == .warning })
        XCTAssertTrue(f.contains { $0.key == "benign" && $0.detail.contains("hop 2") })
    }

    func testSlowWifiFirstHop() {
        let f = diagnose([hop(1, "192.168.1.1", rtt: 40), hop(2, "1.1.1.1", rtt: 50, dest: true)])
        XCTAssertNotNil(f.first { $0.key == "lan-latency" })
    }

    func testUnreachableNearbyIsCritical() {
        let f = diagnose([hop(1, "192.168.1.1", rtt: 2), hop(2, "?", rtt: 0, loss: 100)], reached: false)
        XCTAssertEqual(f.first?.key, "unreachable")
        XCTAssertEqual(f.first?.severity, .critical)
    }

    func testTunnelSuppressesLanAndFirstHopJumpFindings() {
        let hops = [hop(1, "10.10.3.123", rtt: 90), hop(2, "203.0.113.1", rtt: 92), hop(3, "1.1.1.1", rtt: 95, dest: true)]
        let f = PathDiagnosis.diagnose(target: "1.1.1.1", hops: hops, reached: true, names: [:], tunnel: "utun4")
        XCTAssertNil(f.first { $0.key == "lan-latency" || $0.key.hasPrefix("latency@") })
        XCTAssertNotNil(f.first { $0.key == "tunnel" })
    }

    func testSparseHopDoesNotProduceLatencyJump() {
        let f = diagnose([hop(1, "192.168.1.1", rtt: 67, loss: 97), hop(2, "203.0.113.1", rtt: 9),
                          hop(3, "1.1.1.1", rtt: 12, dest: true)])
        XCTAssertNil(f.first { $0.key.hasPrefix("latency@") || $0.key == "lan-latency" })
        XCTAssertNotNil(f.first { $0.key == "healthy" })
    }

    func testTracerScrubsTunnelEchoBurst() {
        func echo(_ ip: String) -> ProbeResult { ProbeResult(kind: .echoReply, responder: ip, rtt: 50) }
        func expired(_ ip: String) -> ProbeResult { ProbeResult(kind: .timeExceeded, responder: ip, rtt: 40) }
        let timeout = ProbeResult(kind: .timeout, responder: nil, rtt: nil)

        var tracer = PathTracer(maxHops: 5)
        // First burst: the tunnel answers every TTL as if it were the destination.
        tracer.apply((1...5).map { ($0, echo("1.1.1.1")) })
        // Then the real path: hop 1 silent, hop 2 a router, destination at TTL 3.
        for _ in 0..<4 {
            tracer.apply([(1, timeout), (2, expired("10.0.0.1")), (3, echo("1.1.1.1")), (4, echo("1.1.1.1")), (5, echo("1.1.1.1"))])
        }
        XCTAssertEqual(tracer.destinationTTL, 3)
        let hops = tracer.hops
        XCTAssertEqual(hops[0].stats.received, 0, "hop 1's fake echo reply should be scrubbed")
        XCTAssertEqual(hops[1].significantResponders, ["10.0.0.1"])
        XCTAssertNil(hops[1].responders["1.1.1.1"])
        XCTAssertTrue(hops[2].isDestination)
    }

    func testStatsJitterAndLoss() {
        let s = ProbeStats([10, nil, 20, 10])
        XCTAssertEqual(s.lossPercent, 25)
        XCTAssertEqual(s.jitter, 10)
        XCTAssertEqual(s.best, 10)
        XCTAssertEqual(s.worst, 20)
    }
}
