import Foundation

// Pure Wi-Fi types and analysis: no CoreWLAN here, so all of it is unit-testable.

enum WiFiBand: String, Codable, CaseIterable, Comparable {
    case ghz2 = "2.4 GHz", ghz5 = "5 GHz", ghz6 = "6 GHz"
    static func < (a: WiFiBand, b: WiFiBand) -> Bool { allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)! }
}

/// A channel as macOS reports it: the primary 20 MHz channel number, band and total width.
struct WiFiChannel: Codable, Hashable {
    let number: Int
    let band: WiFiBand
    let widthMHz: Int

    /// Center frequency of the primary 20 MHz channel.
    var primaryCenterMHz: Int {
        switch band {
        case .ghz2: number == 14 ? 2484 : 2407 + 5 * number
        case .ghz5: 5000 + 5 * number
        case .ghz6: 5950 + 5 * number
        }
    }

    /// Frequency range the whole (possibly bonded) channel occupies.
    var span: ClosedRange<Int> {
        let width = max(20, widthMHz)
        let lowestPrimary: Int
        switch band {
        case .ghz2:
            // 40 MHz on 2.4 GHz: the secondary is conventionally above for channels 1-7, below otherwise.
            lowestPrimary = width >= 40 && number > 7 ? number - 4 : number
            let low = WiFiChannel(number: lowestPrimary, band: band, widthMHz: 20).primaryCenterMHz - 10
            return low...(low + min(width, 40))
        case .ghz5:
            // Bonded blocks are aligned from 36 (36-144) and from 149 (149-177).
            let base = number >= 149 ? 149 : 36
            let slots = width / 20
            lowestPrimary = base + (number - base) / (4 * slots) * (4 * slots)
        case .ghz6:
            let slots = width / 20
            lowestPrimary = 1 + (number - 1) / (4 * slots) * (4 * slots)
        }
        let low = WiFiChannel(number: lowestPrimary, band: band, widthMHz: 20).primaryCenterMHz - 10
        return low...(low + width)
    }

    var centerMHz: Int { (span.lowerBound + span.upperBound) / 2 }

    func overlaps(_ other: WiFiChannel) -> Bool {
        band == other.band && span.lowerBound < other.span.upperBound && other.span.lowerBound < span.upperBound
    }

    /// 5 GHz channels 52-144 need radar detection (DFS): routers may avoid them or leave them for a minute after radar.
    var isDFS: Bool { band == .ghz5 && (52...144).contains(number) }

    var label: String { "\(number) · \(band.rawValue) · \(widthMHz) MHz" }
}

/// BSS Load (802.11 element 11) that some access points put in their beacons.
struct BSSLoad: Codable, Equatable {
    let stationCount: Int
    /// Share of time the AP sensed the channel busy, 0-100.
    let channelUtilizationPercent: Double

    /// Finds element 11 in raw beacon information elements. Tolerates a leading 12-byte fixed header.
    static func parse(_ ie: Data) -> BSSLoad? {
        let b = [UInt8](ie)
        for start in [0, 12] {
            var off = start
            var found: BSSLoad?
            while off + 2 <= b.count {
                let id = b[off], len = Int(b[off + 1])
                guard off + 2 + len <= b.count else { found = nil; off = -1; break }
                if id == 11, len >= 5 {
                    found = BSSLoad(stationCount: Int(b[off + 2]) | Int(b[off + 3]) << 8,
                                    channelUtilizationPercent: (Double(b[off + 4]) / 255 * 1000).rounded() / 10)
                }
                off += 2 + len
            }
            if off == b.count { return found }
        }
        return nil
    }
}

/// The Mac's current association, sampled every couple of seconds (no scan needed).
struct WiFiLink: Codable, Equatable {
    var interfaceName: String
    var poweredOn: Bool
    var connected: Bool
    /// Network name and AP address need Location Services permission; nil without it.
    var ssid: String?
    var bssid: String?
    var rssi: Int
    var noise: Int
    var txRateMbps: Double
    var channel: WiFiChannel?
    var phyMode: String
    var security: String
    var transmitPowerMw: Int
    var countryCode: String?
    /// Whether internet traffic currently leaves through Wi-Fi (not Ethernet).
    var carriesTraffic: Bool

    var snr: Int { rssi - noise }
}

/// One access point seen in a scan.
struct WiFiNetwork: Codable, Equatable, Identifiable {
    var ssid: String?
    var bssid: String?
    var rssi: Int
    var noise: Int
    var channel: WiFiChannel
    var phyModes: [String]
    var security: String
    var load: BSSLoad?
    /// The AP this Mac is associated with.
    var isCurrent: Bool

    var id: String { bssid ?? "\(channel.number)/\(channel.band.rawValue)/\(rssi)/\(ssid ?? "")" }
}

struct WiFiScan: Codable, Equatable {
    let date: Date
    let durationSeconds: Double
    let networks: [WiFiNetwork]
}

/// Per-second link sample kept in memory for the last hour.
struct WiFiSample: Codable, Equatable {
    let t: Date
    let rssi: Int?
    let noise: Int?
    let txRateMbps: Double?
}

/// Per-minute summary persisted to wifi.jsonl for long ranges.
struct WiFiRollup: Codable, Equatable {
    let start: Date
    let samples: Int
    let rssiAvg: Double?
    let rssiMin: Int?
    let noiseAvg: Double?
    let txRateAvg: Double?
    let txRateMin: Double?
    let channel: WiFiChannel?
    let bssid: String?

    static func from(_ samples: [WiFiSample], start: Date, channel: WiFiChannel?, bssid: String?) -> WiFiRollup {
        let rssi = samples.compactMap(\.rssi), noise = samples.compactMap(\.noise), tx = samples.compactMap(\.txRateMbps)
        func mean<T: BinaryInteger>(_ v: [T]) -> Double? { v.isEmpty ? nil : Double(v.reduce(0, +)) / Double(v.count) }
        return WiFiRollup(start: start, samples: samples.count, rssiAvg: mean(rssi), rssiMin: rssi.min(), noiseAvg: mean(noise),
                          txRateAvg: tx.isEmpty ? nil : tx.reduce(0, +) / Double(tx.count), txRateMin: tx.min(),
                          channel: channel, bssid: bssid)
    }
}

// MARK: Congestion

struct ChannelLoad: Codable, Equatable {
    let channel: WiFiChannel
    /// Weighted count of competing APs: a strong neighbor counts ~1, a faint one ~0, plus their reported utilization.
    let score: Double
    /// Other APs on the same primary channel (they share airtime politely).
    let coChannel: Int
    /// Other APs whose channel overlaps but has a different primary (adjacent-channel interference).
    let overlapping: Int
    let isCurrent: Bool
}

enum WiFiAnalysis {
    static func signalQuality(_ rssi: Int) -> String {
        if rssi >= -60 { return "excellent" }
        if rssi >= -67 { return "good" }
        return rssi >= -75 ? "weak" : "very weak"
    }

    /// How much a neighbor at `rssi` dBm competes for airtime: 0 at -90 dBm, 1 at -50 dBm and above.
    static func weight(rssi: Int) -> Double { min(1, max(0, Double(rssi + 90) / 40)) }

    /// Whether two BSSIDs are virtual networks on one radio (e.g. a guest network). Vendors derive them by setting the
    /// locally-administered bit of the first octet and/or changing the last octet, so compare the rest.
    static func sameRadio(_ a: WiFiNetwork, _ b: WiFiNetwork) -> Bool {
        guard a.channel.number == b.channel.number, a.channel.band == b.channel.band,
              let x = octets(a.bssid), let y = octets(b.bssid) else { return false }
        return x[0] & ~0x02 == y[0] & ~0x02 && x[1...4] == y[1...4]
    }

    private static func octets(_ bssid: String?) -> [UInt8]? {
        guard let parts = bssid?.split(separator: ":"), parts.count == 6 else { return nil }
        let bytes = parts.compactMap { UInt8($0, radix: 16) }
        return bytes.count == 6 ? bytes : nil
    }

    /// Networks that actually compete with yours for airtime. Drops your own network (the current AP, other access
    /// points with its name, which move channel with it, and virtual networks on its radio) and counts each other
    /// radio once, however many networks it broadcasts.
    static func competitors(_ neighbors: [WiFiNetwork]) -> [WiFiNetwork] {
        let current = neighbors.first(where: \.isCurrent)
        let name = current?.ssid
        let own = neighbors.filter { $0.isCurrent || (name != nil && $0.ssid == name) }
        var out: [WiFiNetwork] = []
        for n in neighbors.sorted(by: { $0.rssi > $1.rssi }) {
            if n.isCurrent || (name != nil && n.ssid == name) { continue }
            if own.contains(where: { sameRadio($0, n) }) { continue }
            if out.contains(where: { sameRadio($0, n) }) { continue }
            out.append(n)
        }
        return out
    }

    static func load(on channel: WiFiChannel, neighbors: [WiFiNetwork], isCurrent: Bool = false) -> ChannelLoad {
        var score = 0.0, co = 0, overlap = 0
        for n in competitors(neighbors) where n.channel.overlaps(channel) {
            if n.channel.number == channel.number { co += 1 } else { overlap += 1 }
            // Adjacent-channel overlap is worse than co-channel: the radios can't decode each other and back off.
            let kind = n.channel.number == channel.number ? 1.0 : 1.3
            let busy = 1 + (n.load?.channelUtilizationPercent ?? 0) / 100
            score += weight(rssi: n.rssi) * kind * busy
        }
        return ChannelLoad(channel: channel, score: (score * 10).rounded() / 10, coChannel: co, overlapping: overlap, isCurrent: isCurrent)
    }

    /// Channels a router on `band` at `widthMHz` could reasonably pick.
    static func candidates(band: WiFiBand, widthMHz: Int) -> [WiFiChannel] {
        let numbers: [Int]
        switch band {
        case .ghz2: numbers = [1, 6, 11]
        case .ghz5:
            switch widthMHz {
            case 160...: numbers = [36, 100, 149]
            case 80..<160: numbers = [36, 52, 100, 116, 132, 149]
            case 40..<80: numbers = [36, 44, 52, 60, 100, 108, 116, 124, 132, 140, 149, 157]
            default: numbers = [36, 40, 44, 48, 52, 56, 60, 64, 100, 104, 108, 112, 116, 120, 124, 128, 132, 136, 140, 144, 149, 153, 157, 161, 165]
            }
        case .ghz6:
            let step = max(4, widthMHz / 5)
            numbers = Array(stride(from: 1, through: 229, by: step))
        }
        return numbers.map { WiFiChannel(number: $0, band: band, widthMHz: max(20, widthMHz)) }
    }

    /// Load on each candidate channel of the current band, plus the current channel itself.
    static func channelLoads(current: WiFiChannel, neighbors: [WiFiNetwork]) -> [ChannelLoad] {
        var list = candidates(band: current.band, widthMHz: current.widthMHz)
        if !list.contains(where: { $0.span == current.span }) { list.append(current) }
        return list.map { c in load(on: c, neighbors: neighbors, isCurrent: c.span == current.span) }
            .sorted { $0.channel.number < $1.channel.number }
    }

    struct Recommendation: Codable, Equatable {
        let channel: WiFiChannel
        let score: Double
        let currentScore: Double
        let reason: String
    }

    /// A clearly quieter channel on the same band and width, or nil if the current one is fine.
    static func recommendation(current: WiFiChannel, neighbors: [WiFiNetwork]) -> Recommendation? {
        let loads = channelLoads(current: current, neighbors: neighbors)
        guard let mine = loads.first(where: \.isCurrent) else { return nil }
        // Prefer non-DFS channels when they're about as quiet: DFS channels can go silent after radar.
        guard let best = loads.filter({ !$0.isCurrent }).min(by: { a, b in
            (a.score + (a.channel.isDFS ? 0.3 : 0)) < (b.score + (b.channel.isDFS ? 0.3 : 0))
        }) else { return nil }
        guard mine.score >= 1.0, mine.score - best.score >= 1.0 else { return nil }
        var reason = String(format: "Channel %d scores %.1f (%d on the same channel, %d overlapping); channel %d scores %.1f.",
                            current.number, mine.score, mine.coChannel, mine.overlapping, best.channel.number, best.score)
        if best.channel.isDFS { reason += " It is a DFS channel: the router must leave it for a while if it detects radar." }
        reason += " Change it in your router's wireless settings; this Mac can't change it."
        return Recommendation(channel: best.channel, score: best.score, currentScore: mine.score, reason: reason)
    }

    // MARK: Diagnosis

    struct Context {
        var link: WiFiLink?
        var neighbors: [WiFiNetwork] = []
        /// Whether the last scan saw anything (false = never scanned).
        var scanned = false
        /// Roams (AP or channel changes) in the last 10 minutes.
        var recentRoams = 0
        /// Best (lowest) first-hop latency stats across monitored targets.
        var firstHop: ProbeStats?
        var locationAuthorized = false
    }

    static func diagnose(_ c: Context) -> [Finding] {
        guard let link = c.link else {
            return [Finding(severity: .info, key: "wifi-none", title: "No Wi-Fi interface", detail: "This Mac has no Wi-Fi hardware NetMon can read.")]
        }
        guard link.poweredOn else {
            return [Finding(severity: .info, key: "wifi-off", title: "Wi-Fi is off", detail: "Turn Wi-Fi on to see signal and channel data.")]
        }
        guard link.connected, let channel = link.channel else {
            return [Finding(severity: link.carriesTraffic ? .warning : .info, key: "wifi-disconnected", title: "Wi-Fi not connected",
                            detail: "Wi-Fi is on but not joined to a network.")]
        }

        var out: [Finding] = []
        let unused = link.carriesTraffic ? "" : " Your traffic currently goes over another interface (Ethernet), so this doesn't affect your connection."

        switch link.rssi {
        case ..<(-75):
            out.append(Finding(severity: .critical, key: "wifi-signal", title: "Very weak Wi-Fi signal (\(link.rssi) dBm)",
                               detail: "Below -75 dBm, links drop to slow rates and lose packets. Move closer to the router, remove obstructions, or add a mesh node or access point." + unused))
        case ..<(-67):
            out.append(Finding(severity: .warning, key: "wifi-signal", title: "Weak Wi-Fi signal (\(link.rssi) dBm)",
                               detail: "Between -67 and -75 dBm, calls and games start to suffer. Moving closer or adding an access point helps." + unused))
        default: break
        }

        if link.snr < 15 {
            out.append(Finding(severity: .critical, key: "wifi-snr", title: "Very low signal-to-noise ratio (\(link.snr) dB)",
                               detail: "The signal is barely above the background noise (\(link.noise) dBm), so many frames need retransmitting." + unused))
        } else if link.snr < 25 {
            out.append(Finding(severity: .warning, key: "wifi-snr", title: "Low signal-to-noise ratio (\(link.snr) dB)",
                               detail: "Under 25 dB, the link can't use its fastest rates. Either the signal is weak or the noise (\(link.noise) dBm) is high." + unused))
        }
        if link.noise > -75 {
            out.append(Finding(severity: .warning, key: "wifi-noise", title: "High noise floor (\(link.noise) dBm)",
                               detail: "Noise this high usually comes from non-Wi-Fi interference: microwaves, baby monitors, cordless phones, USB 3 hubs or poorly shielded cables near the Mac or router." + unused))
        }

        if link.txRateMbps > 0, link.txRateMbps < 30 {
            out.append(Finding(severity: .warning, key: "wifi-rate", title: String(format: "Low link rate (%.0f Mbps)", link.txRateMbps),
                               detail: "The radio negotiated a slow rate, usually because of weak signal, interference or an old 802.11 mode." + unused))
        }

        if channel.band == .ghz2 {
            let sameNetworkFaster = link.ssid.map { ssid in c.neighbors.contains { $0.ssid == ssid && $0.channel.band != .ghz2 } } ?? false
            if sameNetworkFaster {
                out.append(Finding(severity: .warning, key: "wifi-band", title: "On 2.4 GHz though your network also offers 5/6 GHz",
                                   detail: "2.4 GHz is slower and more crowded. The Mac usually picks 2.4 GHz when 5 GHz is weak here; moving closer to the router lets it switch."))
            } else {
                out.append(Finding(severity: .info, key: "wifi-band", title: "Connected on 2.4 GHz",
                                   detail: "2.4 GHz reaches further but is slower and shared with Bluetooth, microwaves and most neighbors. Use 5 or 6 GHz if your router offers it."))
            }
            if ![1, 6, 11].contains(channel.number) {
                out.append(Finding(severity: .info, key: "wifi-2g-channel", title: "2.4 GHz channel \(channel.number) overlaps its neighbors",
                                   detail: "Only channels 1, 6 and 11 don't overlap each other. Channels in between collide with networks on both sides."))
            }
        }

        if c.recentRoams >= 4 {
            out.append(Finding(severity: .warning, key: "wifi-roaming", title: "Frequent roaming (\(c.recentRoams) in 10 min)",
                               detail: "The Mac keeps switching access point or channel. Each switch causes a short stall. This happens when two access points are about equally strong where you are, or the router changes channel often."))
        }

        if let mine = c.neighbors.first(where: \.isCurrent), let load = mine.load {
            if load.channelUtilizationPercent >= 70 {
                out.append(Finding(severity: .warning, key: "wifi-ap-busy",
                                   title: String(format: "Access point channel %.0f%% busy", load.channelUtilizationPercent),
                                   detail: "Your access point reports the channel busy \(Int(load.channelUtilizationPercent))% of the time with \(load.stationCount) devices connected. Airtime is the bottleneck: move to a quieter channel, use 5/6 GHz, or reduce heavy users."))
            }
        }

        if c.scanned {
            let load = WiFiAnalysis.load(on: channel, neighbors: c.neighbors, isCurrent: true)
            if load.score >= 3 {
                var detail = String(format: "%d other networks share this channel and %d overlap it, with a combined weight of %.1f strong neighbors. They all take turns on the same airtime.",
                                    load.coChannel, load.overlapping, load.score)
                if let rec = recommendation(current: channel, neighbors: c.neighbors) {
                    detail += " Channel \(rec.channel.number) looks quieter (\(String(format: "%.1f", rec.score)))."
                }
                out.append(Finding(severity: load.score >= 5 ? .warning : .info, key: "wifi-crowded",
                                   title: "Crowded channel \(channel.number)", detail: detail))
            }
        }

        // Tie it to the latency NetMon already measures: hop 1 is this Wi-Fi link plus the router.
        if link.carriesTraffic, let hop = c.firstHop, hop.received >= 10, let avg = hop.avg {
            let slow = avg >= 20 || (hop.jitter ?? 0) >= 15 || hop.lossPercent >= 5
            let wifiProblems = out.filter { $0.severity >= .warning }
            if slow, !wifiProblems.isEmpty {
                out.append(Finding(severity: .critical, key: "wifi-cause",
                                   title: "Wi-Fi is the likely cause of first-hop delay",
                                   detail: String(format: "Your router takes %.0f ms on average (jitter %.0f ms, loss %.0f%%) to answer, and the Wi-Fi link shows: %@.",
                                                  avg, hop.jitter ?? 0, hop.lossPercent,
                                                  wifiProblems.map { $0.title.lowercased() }.joined(separator: "; "))))
            } else if slow {
                out.append(Finding(severity: .warning, key: "wifi-router-slow", title: "Router slow to answer, but Wi-Fi looks fine",
                                   detail: String(format: "Hop 1 averages %.0f ms (jitter %.0f ms) while signal and channel look healthy. Suspect a busy or overloaded router, or another device saturating your uplink (bufferbloat).",
                                                  avg, hop.jitter ?? 0)))
            }
        }

        if !c.locationAuthorized {
            out.append(Finding(severity: .info, key: "wifi-location", title: "Network names hidden",
                               detail: "macOS hides network names, access point addresses and beacon data (including access point load) until NetMon has Location Services permission."))
        }

        if !out.contains(where: { $0.severity >= .warning }) {
            out.insert(Finding(severity: .ok, key: "wifi-healthy", title: "Wi-Fi link looks good",
                               detail: "Signal \(link.rssi) dBm, SNR \(link.snr) dB, \(Int(link.txRateMbps)) Mbps on channel \(channel.label)."), at: 0)
        }
        return out.sorted { $0.severity > $1.severity }
    }
}
