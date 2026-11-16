import Foundation

struct ThroughputResult: Codable, Identifiable, Equatable {
    let date: Date
    let downloadMbps: Double
    let uploadMbps: Double
    /// Round-trips per minute under load (Apple's responsiveness metric). Higher is better.
    let responsivenessRPM: Double?
    let baseRTT: Double?
    let interface: String?
    let endpoint: String?
    let megabytesUsed: Double?

    var id: Date { date }

    /// Apple's own rating bands for RPM.
    var responsivenessRating: String {
        guard let rpm = responsivenessRPM else { return "—" }
        switch rpm {
        case ..<300: return "Low"
        case ..<1000: return "Medium"
        default: return "High"
        }
    }
}

/// Runs macOS's built-in `networkQuality` tool, which saturates the link with parallel
/// HTTP/2 flows to Apple's CDN and measures throughput and latency under load.
enum ThroughputTester {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func run() async throws -> ThroughputResult {
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/networkQuality")
            process.arguments = ["-c"]
            let out = Pipe()
            let err = Pipe()
            process.standardOutput = out
            process.standardError = err
            try process.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let msg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                throw Failure(message: msg?.isEmpty == false ? msg! : "networkQuality exited with \(process.terminationStatus)")
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let dl = json["dl_throughput"] as? Double,
                  let ul = json["ul_throughput"] as? Double else {
                throw Failure(message: "Unexpected networkQuality output")
            }
            let bytes = ((json["dl_bytes_transferred"] as? Double) ?? 0) + ((json["ul_bytes_transferred"] as? Double) ?? 0)
            return ThroughputResult(
                date: Date(),
                downloadMbps: dl / 1_000_000,
                uploadMbps: ul / 1_000_000,
                responsivenessRPM: json["responsiveness"] as? Double,
                baseRTT: json["base_rtt"] as? Double,
                interface: json["interface_name"] as? String,
                endpoint: json["test_endpoint"] as? String,
                megabytesUsed: bytes > 0 ? bytes / 1_000_000 : nil)
        }.value
    }
}
