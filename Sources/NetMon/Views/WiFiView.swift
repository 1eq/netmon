import Charts
import SwiftUI

struct WiFiView: View {
    @Environment(AppModel.self) private var model
    @State private var range: TimeRange = .h1
    @State private var mapBand: WiFiBand?

    var body: some View {
        let wifi = model.wifi
        TimelineView(.periodic(from: .now, by: 3)) { _ in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header(wifi)
                    if !wifi.locationAuthorized { LocationBanner(status: wifi.locationStatus) }

                    if let link = wifi.link, link.connected, let ch = link.channel {
                        HStack(spacing: 12) {
                            Card(title: "Signal", value: "\(link.rssi)", unit: "dBm · \(quality(link.rssi))", color: signalColor(link.rssi))
                            Card(title: "Signal-to-noise", value: "\(link.snr)", unit: "dB · noise \(link.noise) dBm",
                                 color: link.snr >= 25 ? .green : link.snr >= 15 ? .orange : .red)
                            Card(title: "Link rate", value: String(format: "%.0f", link.txRateMbps), unit: "Mbps", color: .primary)
                            Card(title: "Channel", value: "\(ch.number)", unit: "\(ch.band.rawValue) · \(ch.widthMHz) MHz\(ch.isDFS ? " · DFS" : "")", color: .primary)
                        }
                        Text(details(link))
                            .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    } else if let link = wifi.link {
                        ContentUnavailableView(link.poweredOn ? "Wi-Fi not connected" : "Wi-Fi is off", systemImage: "wifi.slash")
                    } else if !wifi.hasInterface {
                        ContentUnavailableView("No Wi-Fi interface", systemImage: "wifi.slash")
                    }

                    if !wifi.findings.isEmpty {
                        GroupBox("Diagnosis") {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(wifi.findings) { FindingRow(finding: $0) }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    history(wifi)

                    if let link = wifi.link, let ch = link.channel, wifi.lastScan != nil {
                        channelMap(wifi, current: ch)
                        channelTable(wifi)
                    }
                    if let scan = wifi.lastScan { neighborTable(scan) }
                }
                .padding(24)
            }
        }
    }

    // MARK: Pieces

    private func header(_ wifi: WiFiMonitor) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Wi-Fi").font(.largeTitle).bold()
                Spacer()
                if wifi.scanning {
                    ProgressView().controlSize(.small)
                    Text("Scanning (5–30 s)…")
                } else {
                    Button("Scan now") { wifi.scanNow() }
                        .disabled(wifi.link?.poweredOn != true || model.speedTestRunning)
                }
            }
            Group {
                if let scan = wifi.lastScan {
                    Text("Last scan \(scan.date.formatted(.relative(presentation: .named))), took \(String(format: "%.0f", scan.durationSeconds)) s, found \(scan.networks.count) access points. ")
                    + Text(Prefs.wifiScanMinutes > 0 ? "Scans every \(Int(Prefs.wifiScanMinutes)) min." : "Automatic scans are off.")
                } else {
                    Text("No neighbor scan yet. The first runs about a minute after launch.")
                }
            }
            .font(.callout).foregroundStyle(.secondary)
            Text("A scan takes the radio off your channel for a few seconds, so alerts and hop stats pause for a minute after each one.")
                .font(.caption).foregroundStyle(.secondary)
            if let err = wifi.scanError { Label(err, systemImage: "xmark.octagon").foregroundStyle(.red).font(.callout) }
        }
    }

    @ViewBuilder
    private func history(_ wifi: WiFiMonitor) -> some View {
        let points = wifi.history(range: range)
        GroupBox {
            VStack(alignment: .leading) {
                HStack {
                    Text("Signal and noise (dBm)").font(.headline)
                    Spacer()
                    Picker("Range", selection: $range) {
                        ForEach(TimeRange.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).frame(width: 240)
                }
                if points.isEmpty {
                    Text("No data yet for this range.").foregroundStyle(.secondary).frame(height: 120)
                } else {
                    Chart {
                        // Shaded bands: good / weak / very weak.
                        RectangleMark(yStart: .value("", -67), yEnd: .value("", -40)).foregroundStyle(.green.opacity(0.06))
                        RectangleMark(yStart: .value("", -75), yEnd: .value("", -67)).foregroundStyle(.orange.opacity(0.08))
                        RectangleMark(yStart: .value("", -100), yEnd: .value("", -75)).foregroundStyle(.red.opacity(0.06))
                        ForEach(points) { p in
                            if let v = p.rssiAvg {
                                LineMark(x: .value("Time", p.t), y: .value("dBm", v), series: .value("Series", "Signal"))
                                    .foregroundStyle(by: .value("Series", "Signal"))
                            }
                            if let v = p.noiseAvg {
                                LineMark(x: .value("Time", p.t), y: .value("dBm", v), series: .value("Series", "Noise"))
                                    .foregroundStyle(by: .value("Series", "Noise"))
                            }
                        }
                        ForEach(Array(wifi.roams.enumerated()), id: \.offset) { _, roam in
                            if roam.date >= Date().addingTimeInterval(-range.seconds) {
                                RuleMark(x: .value("Roam", roam.date)).foregroundStyle(.purple.opacity(0.5))
                                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                            }
                        }
                    }
                    .chartYScale(domain: -100 ... -30)
                    .chartXScale(domain: Date().addingTimeInterval(-range.seconds)...Date())
                    .frame(height: 200)

                    Text("Link rate (Mbps)").font(.headline).padding(.top, 8)
                    Chart(points) { p in
                        if let v = p.txRateAvg {
                            AreaMark(x: .value("Time", p.t), y: .value("Mbps", v)).foregroundStyle(.blue.opacity(0.25))
                            LineMark(x: .value("Time", p.t), y: .value("Mbps", v))
                        }
                    }
                    .chartXScale(domain: Date().addingTimeInterval(-range.seconds)...Date())
                    .frame(height: 120)
                    if !wifi.roams.isEmpty {
                        Text("Dashed purple lines mark roams or channel changes.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func channelMap(_ wifi: WiFiMonitor, current: WiFiChannel) -> some View {
        let bands = Set(wifi.neighbors.map(\.channel.band)).sorted()
        let band = mapBand.flatMap { bands.contains($0) ? $0 : nil } ?? current.band
        let nets = wifi.neighbors.filter { $0.channel.band == band }
        let ticks = Self.axisChannels(band: band)
        return GroupBox {
            VStack(alignment: .leading) {
                HStack {
                    Text("Channel map").font(.headline)
                    Spacer()
                    Picker("Band", selection: Binding(get: { band }, set: { mapBand = $0 })) {
                        ForEach(bands, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).frame(width: 240)
                }
                Chart {
                    ForEach(nets) { n in
                        RectangleMark(xStart: .value("MHz", n.channel.span.lowerBound), xEnd: .value("MHz", n.channel.span.upperBound),
                                      yStart: .value("dBm", -95), yEnd: .value("dBm", n.rssi))
                            .foregroundStyle(n.isCurrent ? Color.accentColor.opacity(0.55) : Color.gray.opacity(0.18))
                            .annotation(position: .top, alignment: .center, spacing: 2) {
                                Text(n.isCurrent ? "You" : (n.ssid ?? ""))
                                    .font(.caption2).foregroundStyle(n.isCurrent ? Color.accentColor : .secondary).lineLimit(1)
                            }
                    }
                }
                .chartXScale(domain: (ticks.first.map { WiFiChannel(number: $0, band: band, widthMHz: 20).primaryCenterMHz - 20 } ?? 0)...(ticks.last.map { WiFiChannel(number: $0, band: band, widthMHz: 20).primaryCenterMHz + 20 } ?? 1))
                .chartYScale(domain: -95 ... -25)
                .chartXAxis {
                    AxisMarks(values: ticks.map { WiFiChannel(number: $0, band: band, widthMHz: 20).primaryCenterMHz }) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let mhz = value.as(Int.self), let ch = ticks.first(where: { WiFiChannel(number: $0, band: band, widthMHz: 20).primaryCenterMHz == mhz }) {
                                Text("\(ch)")
                            }
                        }
                    }
                }
                .frame(height: 220)
                Text("Each block is an access point: its width is the channel width, its height the signal at this Mac. Overlapping blocks compete for the same airtime.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func channelTable(_ wifi: WiFiMonitor) -> some View {
        let loads = wifi.channelLoads
        let rec = wifi.recommendation
        return GroupBox("Channel load (\(loads.first?.channel.band.rawValue ?? ""), \(loads.first?.channel.widthMHz ?? 20) MHz)") {
            VStack(alignment: .leading, spacing: 8) {
                if let rec {
                    Label("Consider channel \(rec.channel.number). \(rec.reason)", systemImage: "lightbulb")
                        .font(.callout)
                } else {
                    Text("Score ≈ number of strong competing access points (overlapping ones count extra). Your channel has no clearly quieter alternative.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
                    GridRow {
                        ForEach(["Channel", "Score", "Same channel", "Overlapping", ""], id: \.self) {
                            Text($0).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(loads, id: \.channel) { l in
                        GridRow {
                            Text("\(l.channel.number)\(l.channel.isDFS ? " (DFS)" : "")").monospacedDigit()
                            HStack(spacing: 6) {
                                Capsule().fill(l.score >= 5 ? .red : l.score >= 3 ? .orange : .green)
                                    .frame(width: max(4, min(120, l.score * 20)), height: 6)
                                Text(String(format: "%.1f", l.score)).monospacedDigit()
                            }
                            Text("\(l.coChannel)").monospacedDigit()
                            Text("\(l.overlapping)").monospacedDigit()
                            Text(l.isCurrent ? "yours" : rec?.channel == l.channel ? "suggested" : "")
                                .font(.caption.bold()).foregroundStyle(l.isCurrent ? Color.accentColor : .green)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func neighborTable(_ scan: WiFiScan) -> some View {
        GroupBox("Nearby access points (\(scan.networks.count))") {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow {
                    ForEach(["Network", "Access point", "Channel", "Signal", "Load", "Mode", "Security"], id: \.self) {
                        Text($0).font(.caption).foregroundStyle(.secondary)
                    }
                }
                ForEach(scan.networks) { n in
                    GridRow {
                        HStack(spacing: 4) {
                            if n.isCurrent { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor) }
                            Text(n.ssid ?? (model.wifi.locationAuthorized ? "(hidden)" : "—")).lineLimit(1)
                        }
                        Text(n.bssid ?? "—").font(.caption.monospaced()).foregroundStyle(.secondary)
                        Text("\(n.channel.number) · \(n.channel.band.rawValue) · \(n.channel.widthMHz)").monospacedDigit()
                        Text("\(n.rssi) dBm").monospacedDigit().foregroundStyle(signalColor(n.rssi))
                        Text(n.load.map { String(format: "%.0f%% · %d sta", $0.channelUtilizationPercent, $0.stationCount) } ?? "—")
                            .monospacedDigit()
                        Text(n.phyModes.last?.replacingOccurrences(of: "802.", with: "") ?? "—")
                        Text(n.security).lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Helpers

    private func details(_ l: WiFiLink) -> String {
        var parts = [l.phyMode, l.security]
        if let ssid = l.ssid { parts.insert(ssid, at: 0) }
        if let bssid = l.bssid { parts.append("AP \(bssid)") }
        if let load = model.wifi.neighbors.first(where: \.isCurrent)?.load {
            parts.append(String(format: "AP reports %.0f%% channel busy, %d devices", load.channelUtilizationPercent, load.stationCount))
        }
        parts.append("\(l.interfaceName)\(l.carriesTraffic ? "" : " (not carrying internet traffic: Ethernet is primary)")")
        return parts.joined(separator: " · ")
    }

    private func quality(_ rssi: Int) -> String { WiFiAnalysis.signalQuality(rssi) }

    private func signalColor(_ rssi: Int) -> Color {
        rssi >= -67 ? .green : rssi >= -75 ? .orange : .red
    }

    static func axisChannels(band: WiFiBand) -> [Int] {
        switch band {
        case .ghz2: Array(1...13)
        case .ghz5: [36, 44, 52, 60, 100, 108, 116, 124, 132, 140, 149, 157, 165]
        case .ghz6: Array(stride(from: 1, through: 233, by: 16))
        }
    }
}

private struct Card: View {
    let title: String
    let value: String
    let unit: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 30, weight: .semibold)).monospacedDigit().foregroundStyle(color)
            Text(unit).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct LocationBanner: View {
    let status: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "location.slash").font(.title2).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("Network names are hidden").font(.headline)
                Text(status == "notDetermined"
                     ? "macOS shows network names, access point addresses and access point load only to apps with Location Services permission. Allow NetMon when macOS asks."
                     : "macOS shows network names, access point addresses and access point load only to apps with Location Services permission. Turn on NetMon in System Settings › Privacy & Security › Location Services. Signal, channel and congestion work without it.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Open Location Services settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}
