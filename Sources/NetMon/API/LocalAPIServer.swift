import Foundation
import Network

struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]
    let body: Data
}

struct HTTPResponse {
    var status: Int
    var body: Data

    static func json(_ value: some Encodable, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, body: (try? APIJSON.encoder.encode(value)) ?? Data("{}".utf8))
    }

    static func error(_ status: Int, _ message: String) -> HTTPResponse {
        json(["error": message], status: status)
    }
}

enum APIJSON {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }()
}

/// Where the running app advertises its API. Readable only by the current user (0600), so
/// the bearer token keeps other users and web pages (DNS rebinding, CSRF) out.
struct APIEndpointInfo: Codable {
    let port: UInt16
    let token: String
    let pid: Int32

    static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NetMon/api.json")
    }
}

/// Minimal HTTP/1.1 server bound to 127.0.0.1 on an ephemeral port. One request per
/// connection; plenty for a CLI and an MCP bridge.
final class LocalAPIServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "NetMon.api")
    private var listener: NWListener?
    private let token: String
    private let handler: @Sendable (HTTPRequest) async -> HTTPResponse
    private static let maxRequestBytes = 1 << 20

    init(handler: @escaping @Sendable (HTTPRequest) async -> HTTPResponse) {
        token = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
        self.handler = handler
    }

    func start() {
        do {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            params.allowLocalEndpointReuse = true
            let listener = try NWListener(using: params)
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, let listener else { return }
                switch state {
                case .ready:
                    if let port = listener.port?.rawValue { self.advertise(port: port) }
                case .failed(let error):
                    NSLog("NetMon API listener failed: \(error)")
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            NSLog("NetMon API could not start: \(error)")
        }
    }

    private func advertise(port: UInt16) {
        let info = APIEndpointInfo(port: port, token: token, pid: getpid())
        guard let data = try? JSONEncoder().encode(info) else { return }
        let url = APIEndpointInfo.fileURL
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if error != nil || buffer.count > Self.maxRequestBytes { conn.cancel(); return }
            if let request = Self.parse(buffer) {
                self.respond(conn, to: request)
            } else if isComplete {
                conn.cancel()
            } else {
                self.receive(conn, buffer: buffer)
            }
        }
    }

    private func respond(_ conn: NWConnection, to request: HTTPRequest) {
        let token = self.token
        let handler = self.handler
        Task {
            let response: HTTPResponse
            if request.headers["authorization"] != "Bearer \(token)" {
                response = .error(401, "missing or invalid bearer token (see ~/Library/Application Support/NetMon/api.json)")
            } else {
                response = await handler(request)
            }
            let reason = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found", 409: "Conflict", 500: "Internal Server Error"][response.status] ?? "OK"
            var head = "HTTP/1.1 \(response.status) \(reason)\r\n"
            head += "Content-Type: application/json\r\nContent-Length: \(response.body.count)\r\nConnection: close\r\n\r\n"
            conn.send(content: Data(head.utf8) + response.body, completion: .contentProcessed { _ in conn.cancel() })
        }
    }

    /// Returns a request once headers and the full body have arrived.
    private static func parse(_ data: Data) -> HTTPRequest? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: data[..<headerEnd.lowerBound], encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let body = data[headerEnd.upperBound...]
        guard body.count >= length else { return nil }

        let components = URLComponents(string: String(requestLine[1]))
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return HTTPRequest(method: String(requestLine[0]), path: components?.path ?? "/", query: query,
                           headers: headers, body: Data(body.prefix(length)))
    }
}
