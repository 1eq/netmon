import Charts
import SwiftUI

struct OverviewView: View {
    @Environment(AppModel.self) private var model
    @State private var range: TimeRange = .h1

    var body: some View {
        // Re-render every few seconds so the charts scroll even when nothing else changes.
        TimelineView(.periodic(from: .now, by: 3)) { _ in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        Text("Latency").font(.largeTitle).bold()
                        Spacer()
                        Picker("Range", selection: $range) {
                            ForEach(TimeRange.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 260)
                    }

                    HStack(spacing: 12) {
                        ForEach(model.monitors) { m in
                            StatCard(monitor: m, stats: model.rangeStats(for: m, range: range))
                        }
                    }

                    let points = model.monitors.flatMap { model.chartPoints(for: $0, range: range) }
                    if points.isEmpty {
                        ContentUnavailableView("No data yet for this range", systemImage: "chart.xyaxis.line",
                                               description: Text(range.usesRawSamples ? "Samples arrive every second." : "Long ranges use per-minute history, which starts building once the app has run for a minute."))
                            .frame(height: 300)
                    } else {
                        GroupBox("Round-trip time (ms)") {
                            Chart(points) { p in
                                if let avg = p.avg {
                                    LineMark(x: .value("Time", p.t), y: .value("ms", avg))
                                        .foregroundStyle(by: .value("Target", p.target))
                                        .interpolationMethod(.monotone)
                                }
                            }
                            .chartXScale(domain: Date().addingTimeInterval(-range.seconds)...Date())
                            .frame(height: 260)
                            .padding(.top, 6)
                        }
                        GroupBox("Packet loss (%)") {
                            Chart(points) { p in
                                BarMark(x: .value("Time", p.t, unit: .second), y: .value("Loss", p.lossPercent))
                                    .foregroundStyle(by: .value("Target", p.target))
                            }
                            .chartXScale(domain: Date().addingTimeInterval(-range.seconds)...Date())
                            .chartYScale(domain: 0...max(10, points.map(\.lossPercent).max() ?? 0))
                            .frame(height: 140)
                            .padding(.top, 6)
                        }
                    }

                    let recent = model.events.suffix(5).reversed()
                    if !recent.isEmpty {
                        GroupBox("Recent events") {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(Array(recent)) { EventRow(event: $0) }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(24)
            }
        }
    }
}

private struct StatCard: View {
    let monitor: TargetMonitor
    let stats: ProbeStats

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle().fill(monitor.health.color).frame(width: 9, height: 9)
                TargetName(monitor: monitor, font: .headline.monospaced())
                Spacer()
                Text(monitor.health.label).font(.caption).foregroundStyle(.secondary)
            }
            Text(stats.avg.map { String(format: "%.1f ms", $0) } ?? "—")
                .font(.system(size: 30, weight: .semibold)).monospacedDigit()
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
                GridRow {
                    Metric("min", stats.best.map { String(format: "%.1f", $0) })
                    Metric("max", stats.worst.map { String(format: "%.0f", $0) })
                }
                GridRow {
                    Metric("loss", String(format: "%.2f%%", stats.lossPercent))
                    Metric("jitter", stats.jitter.map { String(format: "%.1f", $0) })
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}
