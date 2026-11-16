import Foundation

/// `netmon <command> [args]`: prints the same JSON the MCP tools return.
///
///     netmon status
///     netmon path [target]
///     netmon history [target] [range]       range: 15m | 1h | 24h | 7d
///     netmon events [limit]
///     netmon throughput [limit]
///     netmon speedtest [--no-wait]
///     netmon trace <host> [cycles]
///     netmon reset [target]
///     netmon open [section]
///     netmon settings
///     netmon set key=value [key=value ...]
enum CLI {
    static var commands: Set<String> { Set(Tools.all.map(\.cliName) + ["help", "--help", "-h", "--mcp"]) }

    static func run(_ args: [String]) -> Never {
        guard let command = args.first, command != "help", command != "--help", command != "-h" else {
            printUsage()
            exit(0)
        }
        guard let tool = Tools.all.first(where: { $0.cliName == command }) else {
            FileHandle.standardError.write(Data("unknown command \(command)\n".utf8))
            printUsage()
            exit(2)
        }
        let rest = Array(args.dropFirst())
        let toolArgs: [String: Any]
        do {
            toolArgs = try arguments(for: command, rest)
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(2)
        }
        Task.detached {
            do {
                let data = try await tool.run(toolArgs)
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data("\n".utf8))
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("netmon: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
        dispatchMain()
    }

    private static func arguments(for command: String, _ rest: [String]) throws -> [String: Any] {
        switch command {
        case "path", "reset":
            return rest.first.map { ["target": $0] } ?? [:]
        case "open":
            return rest.first.map { ["section": $0] } ?? [:]
        case "history":
            var out: [String: Any] = [:]
            for arg in rest {
                if Tools.rangeValues.contains(arg) { out["range"] = arg } else { out["target"] = arg }
            }
            return out
        case "events", "throughput":
            return rest.first.flatMap(Int.init).map { ["limit": $0] } ?? [:]
        case "speedtest":
            return ["wait": !rest.contains("--no-wait")]
        case "trace":
            guard let host = rest.first else { throw APIClient.Failure(message: "usage: netmon trace <host> [cycles]") }
            var out: [String: Any] = ["host": host]
            if let cycles = rest.dropFirst().first.flatMap(Int.init) { out["cycles"] = cycles }
            return out
        case "set":
            var out: [String: Any] = [:]
            for pair in rest {
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { throw APIClient.Failure(message: "expected key=value, got \(pair)") }
                let (key, raw) = (parts[0], parts[1])
                if key == "targets" { out[key] = raw.split(separator: ",").map(String.init) }
                else if raw == "true" || raw == "false" { out[key] = raw == "true" }
                else if let i = Int(raw) { out[key] = i }
                else if let d = Double(raw) { out[key] = d }
                else { out[key] = raw }
            }
            guard !out.isEmpty else {
                throw APIClient.Failure(message: "usage: netmon set key=value ... (keys: \(SettingsAPI.names.joined(separator: ", ")))")
            }
            return out
        default:
            return [:]
        }
    }

    private static func printUsage() {
        print("""
        netmon: query the running NetMon app (JSON output)

          netmon status                      health, latency, loss, findings, last speed test
          netmon path [target]               mtr-style hop table + diagnosis
          netmon history [target] [range]    range: \(Tools.rangeValues.joined(separator: " | "))
          netmon events [limit]              alerts, recoveries, speed tests
          netmon throughput [limit]          speed test history
          netmon speedtest [--no-wait]       run networkQuality (uses hundreds of MB)
          netmon trace <host> [cycles]       one-off trace to any host
          netmon reset [target]              clear hop stats, rediscover route
          netmon open [section]              show the window: overview | path | throughput | events | settings
          netmon settings                    show settings
          netmon set key=value ...           change settings (\(SettingsAPI.names.count) keys; see `netmon settings`)

        Claude Code: claude mcp add --scope user netmon -- /Applications/NetMon.app/Contents/MacOS/NetMon --mcp
        """)
    }
}
