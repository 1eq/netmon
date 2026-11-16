import Charts
import SwiftUI

struct ThroughputView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("Throughput").font(.largeTitle).bold()
                    Spacer()
                    if model.speedTestRunning {
                        ProgressView().controlSize(.small)
                        Text("Running (about 20–40 s)…")
                    } else {
                        Button("Run speed test") { model.runSpeedTest() }
                            .buttonStyle(.borderedProminent)
                    }
                }
                Text("Uses macOS's built-in networkQuality, which saturates your link with parallel flows to Apple's CDN. A run can move hundreds of MB or more, so it never runs on a schedule: only when you click, or automatically when NetMon detects degraded latency, loss or a bad hop (at most once every \(Int(Prefs.speedTestCooldownMinutes)) min). Alerts and hop stats pause while it runs.")
                    .font(.callout).foregroundStyle(.secondary)

                if let err = model.speedTestError {
                    Label(err, systemImage: "xmark.octagon").foregroundStyle(.red)
                }

                if let t = model.lastThroughput {
                    HStack(spacing: 12) {
                        BigNumber(title: "Download", value: String(format: "%.0f", t.downloadMbps), unit: "Mbps")
                        BigNumber(title: "Upload", value: String(format: "%.0f", t.uploadMbps), unit: "Mbps")
                        BigNumber(title: "Responsiveness", value: t.responsivenessRPM.map { String(format: "%.0f", $0) } ?? "—",
                                  unit: "RPM · \(t.responsivenessRating)")
                        BigNumber(title: "Idle RTT", value: t.baseRTT.map { String(format: "%.0f", $0) } ?? "—", unit: "ms")
                    }
                    Text("Last run \(t.date.formatted(date: .abbreviated, time: .shortened)) over \(t.interface ?? "?") to \(t.endpoint ?? "?")\(t.megabytesUsed.map { String(format: ", %.0f MB used", $0) } ?? "")")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if model.throughputHistory.count > 1 {
                    GroupBox("History (Mbps)") {
                        Chart {
                            ForEach(model.throughputHistory) { r in
                                LineMark(x: .value("Date", r.date), y: .value("Mbps", r.downloadMbps), series: .value("Dir", "Download"))
                                    .foregroundStyle(by: .value("Dir", "Download"))
                                    .symbol(.circle)
                                LineMark(x: .value("Date", r.date), y: .value("Mbps", r.uploadMbps), series: .value("Dir", "Upload"))
                                    .foregroundStyle(by: .value("Dir", "Upload"))
                                    .symbol(.square)
                            }
                        }
                        .frame(height: 220)
                    }
                }

                if !model.throughputHistory.isEmpty {
                    GroupBox("All runs") {
                        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
                            GridRow {
                                ForEach(["When", "Down", "Up", "RPM", "Idle RTT", "Interface"], id: \.self) {
                                    Text($0).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            ForEach(model.throughputHistory.reversed()) { r in
                                GridRow {
                                    Text(r.date.formatted(date: .abbreviated, time: .shortened))
                                    Text(String(format: "%.0f", r.downloadMbps)).monospacedDigit()
                                    Text(String(format: "%.0f", r.uploadMbps)).monospacedDigit()
                                    Text(r.responsivenessRPM.map { String(format: "%.0f", $0) } ?? "—").monospacedDigit()
                                    Text(r.baseRTT.map { String(format: "%.0f ms", $0) } ?? "—").monospacedDigit()
                                    Text(r.interface ?? "—")
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(24)
        }
    }
}

private struct BigNumber: View {
    let title: String
    let value: String
    let unit: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 34, weight: .semibold)).monospacedDigit()
            Text(unit).font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}
