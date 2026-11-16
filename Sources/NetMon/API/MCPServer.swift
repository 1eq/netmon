import Foundation

/// Model Context Protocol server over stdio (newline-delimited JSON-RPC 2.0).
/// Run as `NetMon --mcp`; it forwards tool calls to the running app's loopback API.
enum MCPServer {
    static let instructions = """
    NetMon is a macOS menu bar app that continuously monitors this Mac's internet connection: \
    per-second latency to a few public targets (by default 1.1.1.1 and 8.8.8.8; netmon_get_settings \
    lists them) plus a continuous mtr-style hop trace, with history. While the Mac has IPv6 \
    (ipv6Available), each target also gets an IPv6 twin on the same network; a problem on the IPv6 \
    twins only is an IPv6-specific problem.
    Start with netmon_status. Use netmon_path for which hop is at fault, netmon_history or \
    netmon_events for what happened earlier, and netmon_trace for a one-off trace to any other host.
    Interpreting hops: a problem is only real if it carries forward. Loss or high latency at a hop \
    while later hops are clean is ICMP rate limiting by that router, and harmless. Hop 1 is the \
    local router or Wi-Fi; private addresses are the LAN, CGNAT or ISP access network. If \
    tunnelInterface is set, traffic goes through a VPN: the hops are inside the tunnel and the first \
    visible hop includes the whole tunnel's latency. Compare targets: a problem on all of them that \
    starts at the same early hop is local or the ISP; a problem on one is that provider's.
    netmon_run_speed_test uses hundreds of MB and saturates the link. Run it only when bandwidth is \
    actually in question.
    """

    static func run() -> Never {
        Task.detached {
            while let line = readLine(strippingNewline: true) {
                guard !line.isEmpty,
                      let message = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
                if let response = await handle(message) { write(response) }
            }
            exit(0)
        }
        dispatchMain()
    }

    private static func handle(_ message: [String: Any]) async -> [String: Any]? {
        let id = message["id"]
        let method = message["method"] as? String ?? ""
        let params = message["params"] as? [String: Any] ?? [:]
        guard let id else { return nil } // notifications (e.g. notifications/initialized) get no reply

        func result(_ value: [String: Any]) -> [String: Any] { ["jsonrpc": "2.0", "id": id, "result": value] }
        func error(_ code: Int, _ text: String) -> [String: Any] {
            ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": text]]
        }

        switch method {
        case "initialize":
            return result([
                "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "netmon", "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"],
                "instructions": instructions,
            ])
        case "ping":
            return result([:])
        case "tools/list":
            return result(["tools": Tools.all.map { tool in
                [
                    "name": tool.name,
                    "description": tool.description,
                    "inputSchema": tool.inputSchema,
                    "annotations": ["readOnlyHint": tool.readOnly, "openWorldHint": false],
                ] as [String: Any]
            }])
        case "tools/call":
            guard let name = params["name"] as? String, let tool = Tools.named(name) else {
                return error(-32602, "unknown tool \(params["name"] ?? "")")
            }
            let args = params["arguments"] as? [String: Any] ?? [:]
            do {
                let data = try await tool.run(args)
                return result(["content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]], "isError": false])
            } catch {
                return result(["content": [["type": "text", "text": error.localizedDescription]], "isError": true])
            }
        default:
            return error(-32601, "method not found: \(method)")
        }
    }

    private static func write(_ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return }
        data.append(0x0a)
        FileHandle.standardOutput.write(data)
    }
}
