import Charts
import SwiftUI

/// mtr-style hop table plus the diagnosis drawn from it.
struct PathView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedHost: String?

    var body: some View {
        let monitor = model.monitors.first { $0.host == selectedHost } ?? model.monitors.first
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Path").font(.largeTitle).bold()
                Spacer()
                Picker("Target", selection: Binding(get: { monitor?.host ?? "" }, set: { selectedHost = $0 })) {
                    ForEach(model.monitors) { m in
                        Text(m.family == .v6 ? "\(m.host)  (IPv6)" : m.host).tag(m.host)
                    }
                }
                .frame(maxWidth: 340)
                Button("Reset") { monitor?.resetPathStats() }
                    .help("Clear hop statistics and rediscover the route")
            }
            if let monitor {
                PathDetail(monitor: monitor)
            }
        }
        .padding(24)
        // Never ask for more height than the window has: an oversized detail view makes the
        // whole split view taller than the window, which pushes the sidebar out of reach.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct PathDetail: View {
    let monitor: TargetMonitor
    @Environment(AppModel.self) private var model

    var body: some View {
        let hops = monitor.hops
        let flagged = Set(monitor.findings.filter { $0.severity >= .warning }.flatMap(\.hops))
        VStack(alignment: .leading, spacing: 14) {
            if model.speedTestRunning {
                Label("Paused while a speed test runs", systemImage: "pause.circle")
                    .foregroundStyle(.blue)
            }
            // Findings can run long (several multi-line rows); scroll them rather than grow.
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(monitor.findings) { FindingRow(finding: $0) }
                }
            }
            .frame(maxHeight: 150)
            .fixedSize(horizontal: false, vertical: true)

            Table(hops) {
                TableColumn("#") { h in
                    Text("\(h.ttl)").monospacedDigit()
                        .foregroundStyle(flagged.contains(h.ttl) ? .orange : .primary)
                        .bold(flagged.contains(h.ttl))
                }
                .width(28)
                TableColumn("Host") { h in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(monitor.displayName(for: h.primaryAddress)).lineLimit(1)
                        if let ip = h.primaryAddress, monitor.displayName(for: ip) != ip {
                            Text(ip).font(.caption).foregroundStyle(.secondary)
                        }
                        if h.significantResponders.count > 1 {
                            Text("+\(h.significantResponders.count - 1) more (load-balanced)").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                .width(min: 200, ideal: 300)
                TableColumn("Loss") { h in
                    let s = h.stats
                    Text(s.sent == 0 ? "—" : String(format: "%.1f%%", s.lossPercent))
                        .monospacedDigit()
                        .foregroundStyle(lossColor(s.lossPercent, silent: s.received == 0))
                }
                .width(60)
                TableColumn("Sent") { h in Text("\(h.stats.sent)").monospacedDigit() }.width(44)
                TableColumn("Last") { h in ms(h.stats.last) }.width(54)
                TableColumn("Avg") { h in ms(h.stats.avg).bold() }.width(54)
                TableColumn("Best") { h in ms(h.stats.best) }.width(54)
                TableColumn("Worst") { h in ms(h.stats.worst) }.width(54)
                TableColumn("StDev") { h in ms(h.stats.stdev) }.width(54)
                TableColumn("Jitter") { h in ms(h.stats.jitter) }.width(54)
            }
            .frame(minHeight: 120, maxHeight: .infinity)

            GroupBox("Latency profile by hop") {
                Chart(hops) { h in
                    if let avg = h.stats.avg {
                        BarMark(x: .value("Hop", "\(h.ttl)"), yStart: .value("Best", h.stats.best ?? avg), yEnd: .value("Worst", h.stats.worst ?? avg))
                            .foregroundStyle(.gray.opacity(0.3))
                        PointMark(x: .value("Hop", "\(h.ttl)"), y: .value("Avg", avg))
                            .foregroundStyle(flagged.contains(h.ttl) ? .orange : .accentColor)
                    }
                }
                .chartYAxisLabel("ms (bar = best…worst, dot = avg)")
                .frame(height: 100)
            }
            Text("Window: last \(Hop.window) probes per hop, one probe per hop every \(Prefs.traceInterval, specifier: "%.0f")s. Loss or latency at a hop only matters if it carries through to later hops.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func ms(_ v: Double?) -> Text {
        Text(v.map { String(format: "%.1f", $0) } ?? "—").monospacedDigit()
    }

    private func lossColor(_ loss: Double, silent: Bool) -> Color {
        if silent { return .secondary }
        if loss >= 10 { return .red }
        if loss >= 2 { return .orange }
        return .primary
    }
}

struct FindingRow: View {
    let finding: Finding

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(color).font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(finding.title).bold()
                Text(finding.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private var icon: String {
        switch finding.severity {
        case .ok: "checkmark.circle.fill"
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle.fill"
        case .critical: "exclamationmark.octagon.fill"
        }
    }
    private var color: Color {
        switch finding.severity {
        case .ok: .green
        case .info: .blue
        case .warning: .orange
        case .critical: .red
        }
    }
}
