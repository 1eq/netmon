import Foundation

/// Something worth remembering: an alert, a recovery, a speed test.
struct NetEvent: Codable, Identifiable, Equatable {
    enum Level: String, Codable { case info, warning, critical, recovered }
    let date: Date
    let level: Level
    let title: String
    let detail: String
    var id: String { "\(date.timeIntervalSince1970)-\(title)" }
}

/// Append-only JSON Lines files under ~/Library/Application Support/NetMon.
/// Small enough (a week of per-minute rollups is ~20k lines) to load whole at launch.
final class HistoryStore: @unchecked Sendable {
    let directory: URL
    private let queue = DispatchQueue(label: "NetMon.history")

    init() {
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NetMon", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func url(_ name: String) -> URL { directory.appendingPathComponent("\(name).jsonl") }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    func append<T: Encodable>(_ value: T, to name: String) {
        queue.async {
            guard var line = try? Self.encoder.encode(value) else { return }
            line.append(0x0a)
            let file = self.url(name)
            if let handle = try? FileHandle(forWritingTo: file) {
                handle.seekToEndOfFile()
                handle.write(line)
                try? handle.close()
            } else {
                try? line.write(to: file)
            }
        }
    }

    /// Loads every record, dropping (and rewriting the file without) ones older than `cutoff`.
    func load<T: Codable>(_ type: T.Type, from name: String, keepingAfter cutoff: Date, date: (T) -> Date) -> [T] {
        queue.sync {
            guard let data = try? Data(contentsOf: url(name)) else { return [] }
            let all = data.split(separator: 0x0a).compactMap { try? Self.decoder.decode(T.self, from: Data($0)) }
            let kept = all.filter { date($0) >= cutoff }
            if kept.count < all.count {
                let out = kept.compactMap { try? Self.encoder.encode($0) }.reduce(into: Data()) { $0.append($1); $0.append(0x0a) }
                try? out.write(to: url(name), options: .atomic)
            }
            return kept
        }
    }
}
