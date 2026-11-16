import AppKit
import Foundation

/// Talks to the running NetMon app's loopback API, launching the app if it isn't running.
/// Used by the CLI and the MCP bridge, which are the same binary run in a different mode.
enum APIClient {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func get(_ path: String, query: [String: String] = [:], timeout: TimeInterval = 30) async throws -> Data {
        try await send("GET", path, query: query, body: nil, timeout: timeout)
    }

    static func post(_ path: String, body: [String: Any] = [:], timeout: TimeInterval = 30) async throws -> Data {
        try await send("POST", path, query: [:], body: body, timeout: timeout)
    }

    private static func send(_ method: String, _ path: String, query: [String: String], body: [String: Any]?,
                             timeout: TimeInterval) async throws -> Data {
        let info = try await endpoint()
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(info.port)
        components.path = path
        if !query.isEmpty { components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var request = URLRequest(url: components.url!, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("Bearer \(info.token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw Failure(message: message ?? "NetMon API returned HTTP \(status)")
        }
        return data
    }

    /// Reads api.json, launching the app and waiting for it if needed.
    private static func endpoint() async throws -> APIEndpointInfo {
        if let info = liveEndpoint() { return info }
        try launchApp()
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(250))
            if let info = liveEndpoint() { return info }
        }
        throw Failure(message: "NetMon didn't start its API. Try `open -a NetMon` and check it's in the menu bar.")
    }

    private static func liveEndpoint() -> APIEndpointInfo? {
        guard let data = try? Data(contentsOf: APIEndpointInfo.fileURL),
              let info = try? JSONDecoder().decode(APIEndpointInfo.self, from: data),
              kill(info.pid, 0) == 0 else { return nil }
        return info
    }

    private static func launchApp() throws {
        // Prefer the bundle this binary lives in; fall back to whatever LaunchServices finds.
        let ownBundle = Bundle.main.bundleURL
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ownBundle.pathExtension == "app" ? [ownBundle.path] : ["-b", Prefs.bundleID]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure(message: "NetMon isn't running and couldn't be launched. Install it with scripts/build-app.sh --install.")
        }
    }
}
