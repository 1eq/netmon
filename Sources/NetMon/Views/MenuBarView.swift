import Charts
import SwiftUI

struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Circle().fill(model.overallHealth.color).frame(width: 10, height: 10)
                Text(model.overallHealth.label).font(.headline)
                Spacer()
                Text("NetMon").font(.caption).foregroundStyle(.secondary)
            }

            ForEach(model.monitors) { m in
                TargetSummaryRow(monitor: m)
            }

            if let link = model.wifi.link, link.connected, let ch = link.channel {
                Divider()
                WiFiSummaryRow(link: link, channel: ch, finding: model.wifi.worstFinding)
            }

            Divider()
            ThroughputSummary()
            Divider()

            HStack {
                Button("Open NetMon") {
                    openWindow(id: "main")
                    NSApp.activate()
                }
                .keyboardShortcut("o")
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding(14)
        .frame(width: 360)
    }
}

private struct TargetSummaryRow: View {
    let monitor: TargetMonitor

    var body: some View {
        let s = monitor.stats(lastSeconds: 60)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Circle().fill(monitor.health.color).frame(width: 7, height: 7)
                TargetName(monitor: monitor, font: .system(.body, design: .monospaced).bold())
                Spacer()
                Text(s.last.map { String(format: "%.0f ms", $0) } ?? "timeout")
                    .monospacedDigit().font(.title3)
            }
            HStack(spacing: 12) {
                Metric("avg", s.avg.map { String(format: "%.1f", $0) })
                Metric("loss", String(format: "%.0f%%", s.lossPercent))
                Metric("jitter", s.jitter.map { String(format: "%.1f", $0) })
                Metric("hops", monitor.destinationTTL.map(String.init))
            }
            Sparkline(samples: Array(monitor.samples.suffix(120)))
                .frame(height: 30)
            if let f = monitor.worstFinding, f.severity >= .warning {
                Label(f.title, systemImage: f.severity == .critical ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(f.severity == .critical ? .red : .orange)
            }
        }
    }
}

struct Metric: View {
    let name: String
    let value: String?
    init(_ name: String, _ value: String?) { self.name = name; self.value = value }

    var body: some View {
        HStack(spacing: 3) {
            Text(name).foregroundStyle(.secondary)
            Text(value ?? "—").monospacedDigit()
        }
        .font(.caption)
    }
}

struct Sparkline: View {
    let samples: [LatencySample]

    var body: some View {
        Chart {
            ForEach(Array(samples.enumerated()), id: \.offset) { _, s in
                if let rtt = s.rtt {
                    LineMark(x: .value("t", s.t), y: .value("ms", rtt))
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 1.2))
                } else {
                    RuleMark(x: .value("t", s.t))
                        .foregroundStyle(.red.opacity(0.6))
                }
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
    }
}

private struct WiFiSummaryRow: View {
    let link: WiFiLink
    let channel: WiFiChannel
    let finding: Finding?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "wifi")
                Text("Wi-Fi").bold()
                Spacer()
                Text("\(link.rssi) dBm").monospacedDigit()
                    .foregroundStyle(link.rssi >= -67 ? .primary : link.rssi >= -75 ? Color.orange : .red)
            }
            HStack(spacing: 12) {
                Metric("ch", "\(channel.number)")
                Metric("band", channel.band.rawValue)
                Metric("snr", "\(link.snr) dB")
                Metric("rate", String(format: "%.0f", link.txRateMbps))
            }
            if let finding, finding.severity >= .warning {
                Label(finding.title, systemImage: finding.severity == .critical ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(finding.severity == .critical ? .red : .orange)
            }
        }
    }
}

private struct ThroughputSummary: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .center) {
            if let t = model.lastThroughput {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(format: "↓ %.0f  ↑ %.0f Mbps", t.downloadMbps, t.uploadMbps))
                        .monospacedDigit()
                    Text("\(t.responsivenessRating) responsiveness · \(t.date.formatted(.relative(presentation: .named)))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("No speed test yet").foregroundStyle(.secondary)
            }
            Spacer()
            if model.speedTestRunning {
                ProgressView().controlSize(.small)
                Text("Testing…").font(.caption)
            } else {
                Button("Speed test") { model.runSpeedTest() }
            }
        }
    }
}

/// A target's name, with an IPv6 badge on IPv6 targets.
struct TargetName: View {
    let monitor: TargetMonitor
    let font: Font

    var body: some View {
        HStack(spacing: 6) {
            Text(monitor.host).font(font).lineLimit(1).truncationMode(.middle)
            if monitor.family == .v6 {
                Text("IPv6").font(.caption2.bold()).foregroundStyle(.blue)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(.blue.opacity(0.15), in: Capsule())
            }
        }
    }
}
