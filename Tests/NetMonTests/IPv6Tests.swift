import XCTest
@testable import NetMon

final class IPv6Tests: XCTestCase {
    private let id: UInt16 = 0xABCD

    /// An ICMPv6 echo request as we send it: type 128, identifier, sequence, payload.
    private func echoRequest6(seq: UInt16) -> [UInt8] {
        [128, 0, 0, 0, UInt8(id >> 8), UInt8(id & 0xff), UInt8(seq >> 8), UInt8(seq & 0xff)] + [UInt8](repeating: 0x42, count: 16)
    }

    func testParsesEchoReply() {
        var reply = echoRequest6(seq: 7)
        reply[0] = 129
        let r = Pinger.parse6(reply, length: reply.count, identifier: id)
        XCTAssertEqual(r?.0, .echoReply)
        XCTAssertEqual(r?.1, 7)
    }

    func testParsesTimeExceededQuotingOurProbe() {
        // ICMPv6 header (type 3, code 0, checksum, 4 unused) + quoted IPv6 header + our echo request.
        var ipv6Header = [UInt8](repeating: 0, count: 40)
        ipv6Header[0] = 0x60
        ipv6Header[6] = 58 // next header: ICMPv6
        let msg: [UInt8] = [3, 0, 0, 0, 0, 0, 0, 0] + ipv6Header + echoRequest6(seq: 42)
        let r = Pinger.parse6(msg, length: msg.count, identifier: id)
        XCTAssertEqual(r?.0, .timeExceeded)
        XCTAssertEqual(r?.1, 42)

        var unreachable = msg
        unreachable[0] = 1
        XCTAssertEqual(Pinger.parse6(unreachable, length: unreachable.count, identifier: id)?.0, .unreachable)
    }

    func testIgnoresOwnRequestsAndOtherIdentifiers() {
        let own = echoRequest6(seq: 1)
        XCTAssertNil(Pinger.parse6(own, length: own.count, identifier: id), "loopback echoes our request back")
        var foreign = echoRequest6(seq: 1)
        foreign[0] = 129
        XCTAssertNil(Pinger.parse6(foreign, length: foreign.count, identifier: 0x1234))
    }

    func testParsesIPv4TimeExceededWithIPHeader() {
        var outer = [UInt8](repeating: 0, count: 20)
        outer[0] = 0x45
        var inner = [UInt8](repeating: 0, count: 20)
        inner[0] = 0x45
        let probe: [UInt8] = [8, 0, 0, 0, UInt8(id >> 8), UInt8(id & 0xff), 0, 9]
        let msg = outer + [11, 0, 0, 0, 0, 0, 0, 0] + inner + probe
        let r = Pinger.parse4(msg, length: msg.count, identifier: id)
        XCTAssertEqual(r?.0, .timeExceeded)
        XCTAssertEqual(r?.1, 9)
    }

    func testAddressHelpers() {
        XCTAssertEqual(IPFamily(address: "2606:4700:4700::1111"), .v6)
        XCTAssertEqual(IPFamily(address: "1.1.1.1"), .v4)
        XCTAssertNil(IPFamily(address: "example.com"))
        XCTAssertTrue(Resolver.isPrivate("fd12:3456::1"))
        XCTAssertTrue(Resolver.isPrivate("fe80::1"))
        XCTAssertFalse(Resolver.isPrivate("2001:4860:4860::8888"))
        XCTAssertTrue(Resolver.isGlobalUnicast("2001:db8::1"))
        XCTAssertFalse(Resolver.isGlobalUnicast("::"), "macOS reports :: as the local address when there's no IPv6")
        XCTAssertFalse(Resolver.isGlobalUnicast("fe80::1"))
        XCTAssertFalse(Resolver.isGlobalUnicast("fd00::1"))
        XCTAssertTrue(Resolver.isPrivate("100.64.1.1"))
        XCTAssertFalse(Resolver.isPrivate("8.8.8.8"))
    }

    @MainActor
    func testIPv6Twins() {
        XCTAssertEqual(AppModel.ipv6Twin(of: "1.1.1.1")?.host, "2606:4700:4700::1111")
        XCTAssertEqual(AppModel.ipv6Twin(of: "9.9.9.9")?.host, "2620:fe::fe")
        XCTAssertNil(AppModel.ipv6Twin(of: "192.0.2.10"), "unknown IPv4 literal has no twin")
        let host = AppModel.ipv6Twin(of: "example.com")
        XCTAssertEqual(host?.host, "example.com (IPv6)")
        XCTAssertEqual(host?.lookup, "example.com")
        for (v4, v6) in AppModel.ipv6Twins {
            XCTAssertEqual(IPFamily(address: v4), .v4)
            XCTAssertEqual(IPFamily(address: v6), .v6)
        }
    }

    /// A full hop-trace burst to an IPv6 internet address must finish promptly whether or not
    /// this Mac has IPv6. (Without a route, macOS used to wedge sendto and stall the app.)
    func testIPv6TraceBurstDoesNotHang() async {
        let started = Date()
        let results = await PathTracer.probeCycle("2001:4860:4860::8888", limit: 30)
        XCTAssertEqual(results.count, 30)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3, "a cycle is bounded by the 2 s probe timeout")
        let v4 = await Pinger.shared.probe("127.0.0.1", timeout: 1)
        XCTAssertEqual(v4.kind, .echoReply, "IPv4 still works after an IPv6 burst")
        let v6 = await Pinger.shared.probe("::1", timeout: 1)
        XCTAssertEqual(v6.kind, .echoReply, "IPv6 loopback still works after the burst")
    }

    /// Real probes over loopback in both families through the shared sockets.
    func testLoopbackProbes() async {
        let v4 = await Pinger.shared.probe("127.0.0.1", timeout: 1)
        XCTAssertEqual(v4.kind, .echoReply)
        XCTAssertEqual(v4.responder, "127.0.0.1")
        let v6 = await Pinger.shared.probe("::1", timeout: 1)
        XCTAssertEqual(v6.kind, .echoReply)
        XCTAssertEqual(v6.responder, "::1")
    }
}
