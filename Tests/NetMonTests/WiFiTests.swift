import XCTest
@testable import NetMon

final class WiFiTests: XCTestCase {
    private func ch(_ n: Int, _ band: WiFiBand, _ w: Int = 20) -> WiFiChannel { WiFiChannel(number: n, band: band, widthMHz: w) }

    private func net(_ n: Int, _ band: WiFiBand, _ w: Int = 20, rssi: Int = -55, current: Bool = false, load: BSSLoad? = nil, ssid: String? = nil,
                     bssid: String? = nil) -> WiFiNetwork {
        WiFiNetwork(ssid: ssid, bssid: bssid, rssi: rssi, noise: -92, channel: ch(n, band, w), phyModes: [], security: "WPA2 Personal",
                    load: load, isCurrent: current)
    }

    private func link(rssi: Int = -50, noise: Int = -92, rate: Double = 866, channel: WiFiChannel? = WiFiChannel(number: 149, band: .ghz5, widthMHz: 80),
                      ssid: String? = nil, traffic: Bool = true) -> WiFiLink {
        WiFiLink(interfaceName: "en1", poweredOn: true, connected: true, ssid: ssid, bssid: nil, rssi: rssi, noise: noise,
                 txRateMbps: rate, channel: channel, phyMode: "802.11ac", security: "WPA2 Personal", transmitPowerMw: 100,
                 countryCode: "US", carriesTraffic: traffic)
    }

    // MARK: Channel math

    func testCenterFrequencies() {
        XCTAssertEqual(ch(1, .ghz2).primaryCenterMHz, 2412)
        XCTAssertEqual(ch(14, .ghz2).primaryCenterMHz, 2484)
        XCTAssertEqual(ch(36, .ghz5).primaryCenterMHz, 5180)
        XCTAssertEqual(ch(1, .ghz6).primaryCenterMHz, 5955)
    }

    func testBondedSpans() {
        // 80 MHz on 149 covers 149-161 (5735-5815); on 157 it's the same block.
        XCTAssertEqual(ch(149, .ghz5, 80).span, 5735...5815)
        XCTAssertEqual(ch(157, .ghz5, 80).span, 5735...5815)
        XCTAssertEqual(ch(116, .ghz5, 80).span, ch(128, .ghz5, 80).span)
        XCTAssertEqual(ch(100, .ghz5, 160).span, 5490...5650)
        XCTAssertEqual(ch(44, .ghz5, 40).span, 5210...5250)
        XCTAssertEqual(ch(33, .ghz6, 160).span, ch(61, .ghz6, 160).span)
        // 2.4 GHz HT40: secondary above for low channels, below for high ones.
        XCTAssertEqual(ch(1, .ghz2, 40).span, 2402...2442)
        XCTAssertEqual(ch(11, .ghz2, 40).span, 2432...2472) // primary 11 + secondary 7
    }

    func testOverlap() {
        XCTAssertFalse(ch(1, .ghz2).overlaps(ch(6, .ghz2)))
        XCTAssertFalse(ch(6, .ghz2).overlaps(ch(11, .ghz2)))
        XCTAssertTrue(ch(1, .ghz2).overlaps(ch(3, .ghz2)))
        XCTAssertTrue(ch(36, .ghz5, 80).overlaps(ch(48, .ghz5)))
        XCTAssertFalse(ch(36, .ghz5, 80).overlaps(ch(52, .ghz5)))
        XCTAssertFalse(ch(36, .ghz5).overlaps(ch(1, .ghz6)), "different bands never overlap")
    }

    func testDFS() {
        XCTAssertTrue(ch(100, .ghz5).isDFS)
        XCTAssertFalse(ch(149, .ghz5).isDFS)
        XCTAssertFalse(ch(36, .ghz5).isDFS)
    }

    // MARK: BSS Load

    func testParsesBSSLoad() {
        // SSID "ab", then BSS Load: 12 stations, utilization 128/255, capacity 0.
        let ie = Data([0, 2, 0x61, 0x62, 11, 5, 12, 0, 128, 0, 0])
        XCTAssertEqual(BSSLoad.parse(ie), BSSLoad(stationCount: 12, channelUtilizationPercent: 50.2))
    }

    func testParsesBSSLoadAfterFixedHeader() {
        let ie = Data(repeating: 0, count: 12) + Data([11, 5, 3, 1, 255, 0, 0])
        XCTAssertEqual(BSSLoad.parse(ie)?.stationCount, 259)
        XCTAssertEqual(BSSLoad.parse(ie)?.channelUtilizationPercent, 100)
    }

    func testNoBSSLoad() {
        XCTAssertNil(BSSLoad.parse(Data()))
        XCTAssertNil(BSSLoad.parse(Data([0, 2, 0x61, 0x62])))
        XCTAssertNil(BSSLoad.parse(Data([11, 9, 1])), "truncated element")
    }

    // MARK: Congestion

    func testLoadExcludesOwnAPAndWeighsBySignal() {
        let neighbors = [net(6, .ghz2, current: true), net(6, .ghz2, rssi: -50), net(6, .ghz2, rssi: -90), net(4, .ghz2, rssi: -50), net(11, .ghz2, rssi: -40)]
        let load = WiFiAnalysis.load(on: ch(6, .ghz2), neighbors: neighbors)
        XCTAssertEqual(load.coChannel, 2)
        XCTAssertEqual(load.overlapping, 1)
        XCTAssertEqual(load.score, 2.3, accuracy: 0.01) // 1 + 0 + 1.3 adjacent
    }

    func testOwnNetworkIsNotCongestion() {
        let neighbors = [
            net(149, .ghz5, 80, rssi: -52, current: true, ssid: "Home", bssid: "88:3d:24:00:00:10"),
            net(149, .ghz5, 80, rssi: -53, ssid: "Guest", bssid: "8a:3d:24:00:00:10"),  // virtual AP, same radio
            net(149, .ghz5, 80, rssi: -63, ssid: "Home", bssid: "d8:6c:63:00:00:20"),   // mesh node
            net(149, .ghz5, 80, rssi: -62, ssid: "Other", bssid: "da:6c:63:00:00:21"),  // another network on that node
            net(149, .ghz5, 80, rssi: -60, ssid: "Neighbor", bssid: "aa:bb:cc:00:00:01"),
        ]
        let load = WiFiAnalysis.load(on: ch(149, .ghz5, 80), neighbors: neighbors, isCurrent: true)
        // Guest, the mesh node and the mesh node's other network are all ours; only Neighbor competes.
        XCTAssertEqual(load.coChannel, 1)
        XCTAssertEqual(WiFiAnalysis.competitors(neighbors).map(\.ssid), ["Neighbor"])
    }

    func testVirtualNetworksOnOneRadioCountOnce() {
        let neighbors = [net(36, .ghz5, rssi: -50, ssid: "A", bssid: "10:20:30:40:50:60"),
                         net(36, .ghz5, rssi: -51, ssid: "A-guest", bssid: "12:20:30:40:50:61"),
                         net(36, .ghz5, rssi: -52, ssid: "B", bssid: "70:20:30:40:50:60")]
        XCTAssertEqual(WiFiAnalysis.load(on: ch(36, .ghz5), neighbors: neighbors).coChannel, 2)
    }

    func testRecommendsQuieterChannel() {
        let busy = (0..<5).map { _ in net(6, .ghz2, rssi: -50) }
        let rec = WiFiAnalysis.recommendation(current: ch(6, .ghz2), neighbors: busy + [net(1, .ghz2, rssi: -80)])
        XCTAssertEqual(rec?.channel.number, 11)
    }

    func testNoRecommendationWhenQuiet() {
        XCTAssertNil(WiFiAnalysis.recommendation(current: ch(149, .ghz5, 80), neighbors: [net(36, .ghz5, 80, rssi: -70)]))
    }

    // MARK: Diagnosis

    func testHealthyLink() {
        let f = WiFiAnalysis.diagnose(.init(link: link(), locationAuthorized: true))
        XCTAssertEqual(f.first?.key, "wifi-healthy")
        XCTAssertFalse(f.contains { $0.severity >= .warning })
    }

    func testWeakSignalAndLowSNR() {
        let f = WiFiAnalysis.diagnose(.init(link: link(rssi: -78, noise: -88), locationAuthorized: true))
        XCTAssertEqual(f.first { $0.key == "wifi-signal" }?.severity, .critical)
        XCTAssertEqual(f.first { $0.key == "wifi-snr" }?.severity, .critical)
        XCTAssertNil(f.first { $0.key == "wifi-healthy" })
    }

    func testBlamesWiFiForSlowFirstHop() {
        var hop = ProbeStats(Array(repeating: 45.0, count: 20).map(Optional.some))
        hop.jitter = 30
        let f = WiFiAnalysis.diagnose(.init(link: link(rssi: -72), firstHop: hop, locationAuthorized: true))
        XCTAssertEqual(f.first?.key, "wifi-cause")
    }

    func testSlowRouterWithGoodWiFi() {
        let hop = ProbeStats(Array(repeating: 40.0, count: 20).map(Optional.some))
        let f = WiFiAnalysis.diagnose(.init(link: link(), firstHop: hop, locationAuthorized: true))
        XCTAssertNotNil(f.first { $0.key == "wifi-router-slow" })
        XCTAssertNil(f.first { $0.key == "wifi-cause" })
    }

    func testEthernetPrimaryDoesNotBlameWiFi() {
        let hop = ProbeStats(Array(repeating: 45.0, count: 20).map(Optional.some))
        let f = WiFiAnalysis.diagnose(.init(link: link(rssi: -72, traffic: false), firstHop: hop, locationAuthorized: true))
        XCTAssertNil(f.first { $0.key == "wifi-cause" })
        XCTAssertTrue(f.first { $0.key == "wifi-signal" }?.detail.contains("Ethernet") ?? false)
    }

    func testCrowdedChannelAndBusyAP() {
        let busy = (0..<6).map { _ in net(6, .ghz2, rssi: -50) }
        let mine = net(6, .ghz2, rssi: -50, current: true, load: BSSLoad(stationCount: 30, channelUtilizationPercent: 85))
        let f = WiFiAnalysis.diagnose(.init(link: link(channel: ch(6, .ghz2)), neighbors: busy + [mine], scanned: true, locationAuthorized: true))
        XCTAssertEqual(f.first { $0.key == "wifi-crowded" }?.severity, .warning)
        XCTAssertNotNil(f.first { $0.key == "wifi-ap-busy" })
        XCTAssertNotNil(f.first { $0.key == "wifi-band" })
    }

    func testStuckOn24WhenNetworkHas5() {
        let f = WiFiAnalysis.diagnose(.init(link: link(channel: ch(6, .ghz2), ssid: "Home"),
                                            neighbors: [net(36, .ghz5, ssid: "Home")], scanned: true, locationAuthorized: true))
        XCTAssertEqual(f.first { $0.key == "wifi-band" }?.severity, .warning)
    }

    func testFrequentRoaming() {
        let f = WiFiAnalysis.diagnose(.init(link: link(), recentRoams: 5, locationAuthorized: true))
        XCTAssertNotNil(f.first { $0.key == "wifi-roaming" })
    }

    func testRollup() {
        let t = Date()
        let r = WiFiRollup.from([WiFiSample(t: t, rssi: -50, noise: -90, txRateMbps: 800),
                                 WiFiSample(t: t, rssi: -60, noise: -92, txRateMbps: 400),
                                 WiFiSample(t: t, rssi: nil, noise: nil, txRateMbps: nil)],
                                start: t, channel: nil, bssid: nil)
        XCTAssertEqual(r.rssiAvg, -55)
        XCTAssertEqual(r.rssiMin, -60)
        XCTAssertEqual(r.txRateMin, 400)
        XCTAssertEqual(r.samples, 3)
    }
}
