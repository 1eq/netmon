import Foundation

/// One operation exposed to Claude, shared by the MCP server and the CLI so they can't drift.
struct Tool {
    let name: String
    let cliName: String
    let description: String
    /// JSON Schema properties, keyed by argument name.
    let properties: [String: [String: Any]]
    let required: [String]
    let readOnly: Bool
    let run: ([String: Any]) async throws -> Data

    var inputSchema: [String: Any] {
        ["type": "object", "properties": properties, "required": required, "additionalProperties": false]
    }
}

enum Tools {
    static let rangeValues = TimeRange.allCases.map(\.rawValue)

    static let all: [Tool] = [
        Tool(name: "netmon_status", cliName: "status",
             description: "Current connection health. For each monitored target (default 1.1.1.1 and 8.8.8.8): health (ok/degraded/down/unknown), latency, loss and jitter over the last 60 s and 5 min, hop count, VPN tunnel if any, and the important path findings. While the Mac has IPv6, each target also has an IPv6 twin (ipVersion \"IPv6\", twinOf naming the IPv4 target); compare the two to tell an IPv6-only problem from a general one. Also returns the last speed test, the 5 most recent events and the alert thresholds. Start here.",
             properties: [:], required: [], readOnly: true,
             run: { _ in try await APIClient.get("/status") }),

        Tool(name: "netmon_path", cliName: "path",
             description: "mtr-style hop table and diagnosis for a monitored target: per-hop address, reverse DNS, loss %, last/avg/best/worst/stdev/jitter over the last 100 probes, plus findings that name the hop where a problem starts. Read it like mtr: loss or latency at one hop only matters if it carries forward to every later hop. A hop that shows loss while later hops are clean is ICMP rate limiting, which is harmless. Through a VPN, the first visible hop includes the whole tunnel.",
             properties: ["target": ["type": "string", "description": "Monitored host, e.g. \"1.1.1.1\". Omit for all targets."]],
             required: [], readOnly: true,
             run: { args in try await APIClient.get("/path", query: stringArgs(args, ["target"])) }),

        Tool(name: "netmon_history", cliName: "history",
             description: "Latency and loss over time for a target, bucketed for charting, plus a summary for the range. 15m and 1h come from raw per-second samples; 24h and 7d from stored per-minute rollups. Use to answer \"was my connection bad earlier/last night?\".",
             properties: [
                 "target": ["type": "string", "description": "Monitored host. Omit for all targets."],
                 "range": ["type": "string", "enum": rangeValues, "description": "Time window (default 1h)."],
             ],
             required: [], readOnly: true,
             run: { args in try await APIClient.get("/history", query: stringArgs(args, ["target", "range"])) }),

        Tool(name: "netmon_events", cliName: "events",
             description: "Event log, newest first: connection down/restored, degraded latency/loss/jitter, bad-hop findings, speed test results and failures. Persisted across restarts.",
             properties: [
                 "limit": ["type": "integer", "description": "Max events (default 50)."],
                 "since_minutes": ["type": "number", "description": "Only events from the last N minutes."],
             ],
             required: [], readOnly: true,
             run: { args in try await APIClient.get("/events", query: stringArgs(args, ["limit", "since_minutes"])) }),

        Tool(name: "netmon_throughput_history", cliName: "throughput",
             description: "Past speed test results, newest first: download/upload Mbps, responsiveness in RPM (round-trips per minute under load; <300 low, 300-1000 medium, >1000 high), idle RTT, interface and MB used.",
             properties: ["limit": ["type": "integer", "description": "Max results (default 20)."]],
             required: [], readOnly: true,
             run: { args in try await APIClient.get("/throughput", query: stringArgs(args, ["limit"])) }),

        Tool(name: "netmon_run_speed_test", cliName: "speedtest",
             description: "Runs a throughput test with macOS networkQuality. It saturates the connection for 20-40 s and moves hundreds of MB or more, so only run it when bandwidth is actually in question, and never repeatedly. It disrupts calls and other traffic while it runs. Alerts and hop stats pause during the test. With wait=true (default) it returns the result.",
             properties: ["wait": ["type": "boolean", "description": "Wait for the result (default true, up to ~90 s)."]],
             required: [], readOnly: false,
             run: { args in try await APIClient.post("/speedtest", body: args, timeout: 120) }),

        Tool(name: "netmon_trace", cliName: "trace",
             description: "One-off mtr-style trace and diagnosis to any host, e.g. a work API, VPN endpoint or game server, without adding it as a monitored target. Probes every hop for `cycles` rounds (default 15, max 60). A round takes 1 s, or about 2 s when some hops never answer, so allow up to ~2 min and returns the same hop table and findings as netmon_path. Uses IPv4 unless the host is an IPv6 address or has no IPv4 address.",
             properties: [
                 "host": ["type": "string", "description": "Hostname, IPv4 or IPv6 address."],
                 "cycles": ["type": "integer", "description": "Probe rounds, one per second (3-60, default 15)."],
                 "max_hops": ["type": "integer", "description": "Max TTL (default 30)."],
             ],
             required: ["host"], readOnly: true,
             run: { args in try await APIClient.post("/trace", body: args, timeout: 120) }),

        Tool(name: "netmon_reset_path", cliName: "reset",
             description: "Clears hop statistics and rediscovers the route for one or all targets. Use after switching networks or VPN state, so old hops don't skew the diagnosis.",
             properties: ["target": ["type": "string", "description": "Monitored host. Omit for all."]],
             required: [], readOnly: false,
             run: { args in try await APIClient.post("/reset", body: args) }),

        Tool(name: "netmon_open_window", cliName: "open",
             description: "Opens the NetMon window on the user's screen at a section, to show them something (e.g. the Path screen while discussing a bad hop). Only when the user asks to see it.",
             properties: ["section": ["type": "string", "enum": SidebarItem.allCases.map { $0.rawValue.lowercased() },
                                      "description": "Section to show (default overview)."]],
             required: [], readOnly: false,
             run: { args in try await APIClient.post("/open", body: args) }),

        Tool(name: "netmon_get_settings", cliName: "settings",
             description: "Current NetMon settings: targets, probe intervals, alert thresholds, notification and auto-speed-test options.",
             properties: [:], required: [], readOnly: true,
             run: { _ in try await APIClient.get("/settings") }),

        Tool(name: "netmon_update_settings", cliName: "set",
             description: "Changes NetMon settings. Pass only the fields to change; values are range-checked and the call fails without changing anything if any is invalid. Returns the full settings afterwards. Changing targets restarts monitoring for new hosts only.",
             properties: [
                 "targets": ["type": "array", "items": ["type": "string"], "description": "Hosts to monitor."],
                 "ping_interval_seconds": ["type": "number", "description": "0.5-10"],
                 "trace_interval_seconds": ["type": "number", "description": "1-30"],
                 "max_hops": ["type": "integer", "description": "5-64"],
                 "loss_alert_percent": ["type": "number", "description": "1-50"],
                 "latency_alert_ms": ["type": "number", "description": "20-1000"],
                 "jitter_alert_ms": ["type": "number", "description": "5-200"],
                 "notifications_enabled": ["type": "boolean"],
                 "notify_path_findings": ["type": "boolean"],
                 "auto_speed_test": ["type": "boolean", "description": "Run a speed test when an alert fires."],
                 "speed_test_cooldown_minutes": ["type": "number", "description": "15-1440"],
                 "min_download_mbps": ["type": "number", "description": "Alert below this; 0 = off."],
                 "history_days": ["type": "integer", "description": "1-90"],
             ],
             required: [], readOnly: false,
             run: { args in try await APIClient.post("/settings", body: args) }),
    ]

    static func named(_ name: String) -> Tool? { all.first { $0.name == name } }

    private static func stringArgs(_ args: [String: Any], _ keys: [String]) -> [String: String] {
        var out: [String: String] = [:]
        for key in keys { if let v = args[key] { out[key] = "\(v)" } }
        return out
    }
}
