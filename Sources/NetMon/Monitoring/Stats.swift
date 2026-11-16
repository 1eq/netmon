import Foundation

/// Summary of a window of probe results (`nil` = lost).
struct ProbeStats: Equatable {
    var sent = 0
    var received = 0
    var last: Double?
    var best: Double?
    var worst: Double?
    var avg: Double?
    var stdev: Double?
    /// Mean absolute difference between consecutive answered RTTs (RFC 3550 style).
    var jitter: Double?

    var lossPercent: Double { sent == 0 ? 0 : Double(sent - received) / Double(sent) * 100 }

    init() {}

    init(_ results: some BidirectionalCollection<Double?>) {
        sent = results.count
        let rtts = results.compactMap { $0 }
        received = rtts.count
        last = results.last ?? nil
        guard !rtts.isEmpty else { return }
        best = rtts.min()
        worst = rtts.max()
        let mean = rtts.reduce(0, +) / Double(rtts.count)
        avg = mean
        stdev = (rtts.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(rtts.count)).squareRoot()
        if rtts.count > 1 {
            jitter = zip(rtts.dropFirst(), rtts).map { abs($0 - $1) }.reduce(0, +) / Double(rtts.count - 1)
        }
    }
}

/// A timestamped latency sample from the once-a-second pinger.
struct LatencySample: Codable, Equatable {
    let t: Date
    let rtt: Double?
}

/// One minute of latency samples, persisted for long-range charts.
struct MinuteRollup: Codable, Equatable {
    let target: String
    let start: Date
    let sent: Int
    let received: Int
    let avg: Double?
    let min: Double?
    let max: Double?
    let jitter: Double?

    var lossPercent: Double { sent == 0 ? 0 : Double(sent - received) / Double(sent) * 100 }
}

/// A chart point: averaged latency plus loss for a time bucket.
struct ChartPoint: Identifiable {
    let target: String
    let t: Date
    let avg: Double?
    let max: Double?
    let lossPercent: Double
    var id: String { "\(target)-\(t.timeIntervalSince1970)" }
}

enum Bucketing {
    static func fromSamples(_ samples: [LatencySample], target: String, bucket: TimeInterval) -> [ChartPoint] {
        group(samples, by: bucket, time: \.t).map { start, items in
            let s = ProbeStats(items.map(\.rtt))
            return ChartPoint(target: target, t: start, avg: s.avg, max: s.worst, lossPercent: s.lossPercent)
        }
    }

    static func fromRollups(_ rollups: [MinuteRollup], target: String, bucket: TimeInterval) -> [ChartPoint] {
        group(rollups, by: bucket, time: \.start).map { start, items in
            let sent = items.reduce(0) { $0 + $1.sent }
            let received = items.reduce(0) { $0 + $1.received }
            // Weight each minute's average by how many replies it had.
            let weighted = items.compactMap { r in r.avg.map { ($0 * Double(r.received), r.received) } }
            let n = weighted.reduce(0) { $0 + $1.1 }
            let avg = n > 0 ? weighted.reduce(0) { $0 + $1.0 } / Double(n) : nil
            let loss = sent == 0 ? 0 : Double(sent - received) / Double(sent) * 100
            return ChartPoint(target: target, t: start, avg: avg, max: items.compactMap(\.max).max(), lossPercent: loss)
        }
    }

    private static func group<T>(_ items: [T], by bucket: TimeInterval, time: KeyPath<T, Date>) -> [(Date, [T])] {
        var buckets: [TimeInterval: [T]] = [:]
        for item in items {
            let key = (item[keyPath: time].timeIntervalSince1970 / bucket).rounded(.down) * bucket
            buckets[key, default: []].append(item)
        }
        return buckets.keys.sorted().map { (Date(timeIntervalSince1970: $0), buckets[$0]!) }
    }
}
