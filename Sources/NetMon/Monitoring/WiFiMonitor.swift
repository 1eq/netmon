import CoreLocation
import CoreWLAN
import Foundation
import Observation
import SystemConfiguration

/// Reads CoreWLAN. Every call may block briefly on XPC (a scan for many seconds), so callers run it off the main actor.
enum WiFiReader {
    static func link() -> WiFiLink? {
        guard let i = CWWiFiClient.shared().interface() else { return nil }
        let name = i.interfaceName ?? "en0"
        let channel = i.wlanChannel().flatMap(channel)
        let connected = i.powerOn() && channel != nil && i.rssiValue() != 0
        return WiFiLink(interfaceName: name, poweredOn: i.powerOn(), connected: connected,
                        ssid: i.ssid(), bssid: i.bssid(), rssi: i.rssiValue(), noise: i.noiseMeasurement(),
                        txRateMbps: i.transmitRate(), channel: channel, phyMode: phyName(i.activePHYMode().rawValue),
                        security: securityName(i.security().rawValue), transmitPowerMw: i.transmitPower(),
                        countryCode: i.countryCode(), carriesTraffic: connected && carriesTraffic(wifi: name))
    }

    /// Scans all channels. Takes several seconds (26 s has been seen) and takes the radio off-channel meanwhile.
    static func scan() throws -> [WiFiNetwork] {
        guard let i = CWWiFiClient.shared().interface() else { return [] }
        let found = try i.scanForNetworks(withSSID: nil, includeHidden: true)
        return found.compactMap { n -> WiFiNetwork? in
            guard let ch = n.wlanChannel.flatMap(channel) else { return nil }
            let phys = [(CWPHYMode.mode11a, "a"), (.mode11b, "b"), (.mode11g, "g"), (.mode11n, "n"), (.mode11ac, "ac"), (.mode11ax, "ax")]
                .filter { n.supportsPHYMode($0.0) }.map { "802.11\($0.1)" }
            let securities: [(CWSecurity, String)] = [(.wpa3Personal, "WPA3 Personal"), (.wpa3Transition, "WPA2/WPA3 Personal"),
                                                      (.wpa2Personal, "WPA2 Personal"), (.wpa3Enterprise, "WPA3 Enterprise"),
                                                      (.wpa2Enterprise, "WPA2 Enterprise"), (.OWE, "Enhanced Open"),
                                                      (.wpaPersonal, "WPA Personal"), (.WEP, "WEP"), (.none, "Open")]
            let security = securities.first { n.supportsSecurity($0.0) }?.1 ?? "Unknown"
            return WiFiNetwork(ssid: n.ssid, bssid: n.bssid, rssi: n.rssiValue, noise: n.noiseMeasurement, channel: ch,
                               phyModes: phys, security: security, load: n.informationElementData.flatMap(BSSLoad.parse),
                               isCurrent: false)
        }
        .sorted { $0.rssi > $1.rssi }
    }

    private static func channel(_ c: CWChannel) -> WiFiChannel? {
        let band: WiFiBand
        switch c.channelBand.rawValue {
        case 1: band = .ghz2
        case 2: band = .ghz5
        case 3: band = .ghz6
        default: band = c.channelNumber <= 14 ? .ghz2 : .ghz5
        }
        let width = [1: 20, 2: 40, 3: 80, 4: 160][c.channelWidth.rawValue] ?? 20
        return WiFiChannel(number: c.channelNumber, band: band, widthMHz: width)
    }

    static func phyName(_ raw: Int) -> String {
        let names = ["None", "802.11a", "802.11b", "802.11g", "802.11n (Wi-Fi 4)", "802.11ac (Wi-Fi 5)",
                     "802.11ax (Wi-Fi 6/6E)", "802.11be (Wi-Fi 7)"]
        return names.indices.contains(raw) ? names[raw] : "Unknown"
    }

    static func securityName(_ raw: Int) -> String {
        let names = [0: "Open", 1: "WEP", 2: "WPA Personal", 3: "WPA/WPA2 Personal", 4: "WPA2 Personal", 5: "Personal",
                     6: "Dynamic WEP", 7: "WPA Enterprise", 8: "WPA/WPA2 Enterprise", 9: "WPA2 Enterprise", 10: "Enterprise",
                     11: "WPA3 Personal", 12: "WPA3 Enterprise", 13: "WPA2/WPA3 Personal", 14: "Enhanced Open", 15: "Enhanced Open (transition)"]
        return names[raw] ?? "Unknown"
    }

    /// True when the primary interface is Wi-Fi, or a VPN tunnel while no wired interface is primary.
    private static func carriesTraffic(wifi: String) -> Bool {
        guard let store = SCDynamicStoreCreate(nil, "NetMon" as CFString, nil, nil),
              let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let primary = global["PrimaryInterface"] as? String else { return true }
        if primary == wifi { return true }
        // A VPN on top of Wi-Fi: the tunnel is primary but packets still ride the Wi-Fi link.
        return primary.hasPrefix("utun") || primary.hasPrefix("ipsec") || primary.hasPrefix("ppp")
    }
}

/// Location Services permission, which macOS requires before it reveals network names, AP addresses and beacon data.
@MainActor
final class LocationPermission: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    var onChange: (() -> Void)?

    override init() {
        super.init()
        manager.delegate = self
    }

    var status: CLAuthorizationStatus { manager.authorizationStatus }
    var authorized: Bool { status == .authorizedAlways || status.rawValue == 4 /* authorizedWhenInUse */ }
    var statusName: String {
        switch status {
        case .notDetermined: "notDetermined"
        case .restricted: "restricted"
        case .denied: "denied"
        default: authorized ? "authorized" : "unknown"
        }
    }

    /// Prompts once. Only inside the .app bundle: a bare binary has no usage string and is denied silently.
    func requestIfNeeded() {
        guard Bundle.main.bundleURL.pathExtension == "app", status == .notDetermined else { return }
        manager.requestWhenInUseAuthorization()
        // A menu bar app sometimes only shows the prompt once it actually asks for a location.
        manager.startUpdatingLocation()
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            if status != .notDetermined { self.manager.stopUpdatingLocation() }
            onChange?()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated { self.manager.stopUpdatingLocation() }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}

/// Samples the Wi-Fi link every 2 s, scans neighbors on a schedule, records roams and per-minute history.
@MainActor
@Observable
final class WiFiMonitor {
    static let sampleInterval: TimeInterval = 2
    /// Alerts and hop stats pause this long after a scan, since the scan itself causes latency spikes.
    static let scanQuietSeconds: TimeInterval = 60

    private(set) var link: WiFiLink?
    private(set) var hasInterface = true
    private(set) var samples: [WiFiSample] = []
    private(set) var rollups: [WiFiRollup] = []
    private(set) var lastScan: WiFiScan?
    private(set) var scanning = false
    private(set) var scanError: String?
    private(set) var findings: [Finding] = []
    /// Times the AP or channel changed, for the last hour.
    private(set) var roams: [(date: Date, detail: String)] = []
    private(set) var locationStatus = "unknown"
    private(set) var locationAuthorized = false

    @ObservationIgnored private var lastScanEnded: Date?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var location: LocationPermission?
    @ObservationIgnored private unowned let model: AppModel
    @ObservationIgnored private var scanTask: Task<WiFiScan?, Never>?

    init(model: AppModel) {
        self.model = model
    }

    var inScanQuietPeriod: Bool {
        scanning || lastScanEnded.map { Date().timeIntervalSince($0) < Self.scanQuietSeconds } ?? false
    }

    var neighbors: [WiFiNetwork] { lastScan?.networks ?? [] }
    var worstFinding: Finding? { findings.max { $0.severity < $1.severity } }

    var channelLoads: [ChannelLoad] {
        guard let ch = link?.channel, lastScan != nil else { return [] }
        return WiFiAnalysis.channelLoads(current: ch, neighbors: neighbors)
    }

    var recommendation: WiFiAnalysis.Recommendation? {
        guard let ch = link?.channel, lastScan != nil else { return nil }
        return WiFiAnalysis.recommendation(current: ch, neighbors: neighbors)
    }

    func start(loadingAfter cutoff: Date) {
        rollups = model.store.load(WiFiRollup.self, from: "wifi", keepingAfter: cutoff) { $0.start }
        let location = LocationPermission()
        location.onChange = { [weak self] in self?.locationChanged() }
        self.location = location
        locationChanged()
        location.requestIfNeeded()

        tasks.append(Task { await sampleLoop() })
        tasks.append(Task { await scanLoop() })
        tasks.append(Task { await rollupLoop() })
    }

    private func locationChanged() {
        guard let location else { return }
        let was = locationAuthorized
        locationStatus = location.statusName
        locationAuthorized = location.authorized
        // Names only come with the permission: rescan once it's granted so the table fills in.
        if locationAuthorized, !was, lastScan != nil { scanNow() }
    }

    // MARK: Sampling

    private func sampleLoop() async {
        var lastDiagnosis = Date.distantPast
        while !Task.isCancelled {
            let read = await Task.detached(priority: .utility) { WiFiReader.link() }.value
            hasInterface = read != nil
            if let read { observe(read) }
            link = read
            if Date().timeIntervalSince(lastDiagnosis) >= 5 {
                lastDiagnosis = Date()
                diagnose()
            }
            try? await Task.sleep(for: .seconds(Self.sampleInterval))
        }
    }

    private func observe(_ new: WiFiLink) {
        samples.append(new.connected
                       ? WiFiSample(t: Date(), rssi: new.rssi, noise: new.noise, txRateMbps: new.txRateMbps)
                       : WiFiSample(t: Date(), rssi: nil, noise: nil, txRateMbps: nil))
        let cutoff = Date().addingTimeInterval(-TargetMonitor.sampleRetention)
        if let first = samples.first, first.t < cutoff { samples.removeAll { $0.t < cutoff } }
        roams.removeAll { $0.date < cutoff }

        guard let old = link else { return }
        if old.connected, !new.connected {
            model.record(NetEvent(date: Date(), level: .warning, title: "Wi-Fi disconnected",
                                  detail: new.poweredOn ? "Left the network." : "Wi-Fi was turned off."))
        } else if !old.connected, new.connected, let ch = new.channel {
            model.record(NetEvent(date: Date(), level: .recovered, title: "Wi-Fi connected",
                                  detail: "\(new.ssid.map { "\($0), " } ?? "")channel \(ch.label), \(new.rssi) dBm."))
        } else if old.connected, new.connected, let oc = old.channel, let nc = new.channel {
            let apChanged = old.bssid != nil && new.bssid != nil && old.bssid != new.bssid
            let channelChanged = oc != nc
            guard apChanged || channelChanged else { return }
            let detail = (apChanged ? "Access point \(old.bssid!) → \(new.bssid!). " : "")
                + "Channel \(oc.label) → \(nc.label). Signal \(old.rssi) → \(new.rssi) dBm."
            roams.append((Date(), detail))
            model.record(NetEvent(date: Date(), level: .info, title: apChanged ? "Wi-Fi roamed" : "Wi-Fi channel changed", detail: detail))
        }
    }

    private func diagnose() {
        let firstHop = model.monitors
            .filter { $0.tunnelInterface == nil }
            .compactMap { $0.hops.first { $0.ttl == 1 }?.stats }
            .filter { $0.received >= 10 }
            .min { ($0.avg ?? .infinity) < ($1.avg ?? .infinity) }
        let tenMinutesAgo = Date().addingTimeInterval(-600)
        findings = hasInterface || link != nil
            ? WiFiAnalysis.diagnose(.init(link: link, neighbors: neighbors, scanned: lastScan != nil,
                                          recentRoams: roams.filter { $0.date >= tenMinutesAgo }.count,
                                          firstHop: firstHop, locationAuthorized: locationAuthorized))
            : []
    }

    // MARK: Scanning

    private func scanLoop() async {
        // Let the first minute of latency data settle before the first scan disturbs it.
        try? await Task.sleep(for: .seconds(45))
        while !Task.isCancelled {
            let minutes = Prefs.wifiScanMinutes
            let due = minutes > 0 && (lastScan.map { Date().timeIntervalSince($0.date) >= minutes * 60 } ?? true)
            if due, link?.poweredOn == true, !model.speedTestRunning {
                _ = await runScan()
            }
            try? await Task.sleep(for: .seconds(30))
        }
    }

    func scanNow() {
        guard !scanning else { return }
        Task { _ = await runScan() }
    }

    /// Runs a scan (or joins the one in progress) and returns it.
    func runScan() async -> WiFiScan? {
        if let scanTask { return await scanTask.value }
        scanning = true
        scanError = nil
        let task = Task<WiFiScan?, Never> {
            let started = Date()
            let result = await Task.detached(priority: .utility) { Result { try WiFiReader.scan() } }.value
            scanning = false
            lastScanEnded = Date()
            scanTask = nil
            switch result {
            case .success(var networks):
                markCurrent(&networks)
                let scan = WiFiScan(date: started, durationSeconds: (Date().timeIntervalSince(started) * 10).rounded() / 10, networks: networks)
                lastScan = scan
                diagnose()
                return scan
            case .failure(let error):
                scanError = error.localizedDescription
                return nil
            }
        }
        scanTask = task
        return await task.value
    }

    /// Flags the AP this Mac is on: by address when known, else the closest-signal match on our channel.
    private func markCurrent(_ networks: inout [WiFiNetwork]) {
        guard let link, link.connected, let ch = link.channel else { return }
        if let bssid = link.bssid, let i = networks.firstIndex(where: { $0.bssid == bssid }) {
            networks[i].isCurrent = true
            return
        }
        let match = networks.indices
            .filter { networks[$0].channel.number == ch.number && networks[$0].channel.band == ch.band && abs(networks[$0].rssi - link.rssi) <= 6 }
            .min { abs(networks[$0].rssi - link.rssi) < abs(networks[$1].rssi - link.rssi) }
        if let match { networks[match].isCurrent = true }
    }

    // MARK: History

    private func rollupLoop() async {
        while !Task.isCancelled {
            let now = Date().timeIntervalSince1970
            let nextMinute = (now / 60).rounded(.down) * 60 + 60
            try? await Task.sleep(for: .seconds(nextMinute - now + 1))
            if Task.isCancelled { return }
            let end = Date(timeIntervalSince1970: nextMinute)
            let start = end.addingTimeInterval(-60)
            let window = samples.filter { $0.t >= start && $0.t < end }
            guard !window.isEmpty, window.contains(where: { $0.rssi != nil }) else { continue }
            let r = WiFiRollup.from(window, start: start, channel: link?.channel, bssid: link?.bssid)
            rollups.append(r)
            model.store.append(r, to: "wifi")
            let cutoff = Date().addingTimeInterval(-Double(Prefs.historyDays) * 86_400)
            if let first = rollups.first, first.start < cutoff { rollups.removeAll { $0.start < cutoff } }
        }
    }

    struct HistoryPoint: Identifiable {
        let t: Date
        let rssiAvg: Double?
        let rssiMin: Double?
        let noiseAvg: Double?
        let txRateAvg: Double?
        var id: Date { t }
    }

    /// Signal, noise and link-rate history in `bucket`-second buckets.
    func history(range: TimeRange, bucket: TimeInterval? = nil) -> [HistoryPoint] {
        let size = bucket ?? range.bucket
        let cutoff = Date().addingTimeInterval(-range.seconds)
        func key(_ d: Date) -> Date { Date(timeIntervalSince1970: (d.timeIntervalSince1970 / size).rounded(.down) * size) }
        func mean(_ v: [Double]) -> Double? { v.isEmpty ? nil : v.reduce(0, +) / Double(v.count) }
        var points: [HistoryPoint] = []
        if range.usesRawSamples {
            let groups = Dictionary(grouping: samples.filter { $0.t >= cutoff }) { key($0.t) }
            for (t, s) in groups {
                let rssi: [Double] = s.compactMap { $0.rssi.map(Double.init) }
                let noise: [Double] = s.compactMap { $0.noise.map(Double.init) }
                let tx: [Double] = s.compactMap(\.txRateMbps)
                points.append(HistoryPoint(t: t, rssiAvg: mean(rssi), rssiMin: rssi.min(), noiseAvg: mean(noise), txRateAvg: mean(tx)))
            }
        } else {
            let groups = Dictionary(grouping: rollups.filter { $0.start >= cutoff }) { key($0.start) }
            for (t, r) in groups {
                let rssiMin: Double? = r.compactMap(\.rssiMin).min().map(Double.init)
                points.append(HistoryPoint(t: t, rssiAvg: mean(r.compactMap(\.rssiAvg)), rssiMin: rssiMin,
                                           noiseAvg: mean(r.compactMap(\.noiseAvg)), txRateAvg: mean(r.compactMap(\.txRateAvg))))
            }
        }
        return points.sorted { $0.t < $1.t }
    }
}
