import Foundation
import Network

/// A local MCP server speaking the Streamable HTTP transport.
///
/// Why it exists: the trading engines (`RankedOrderBlocks`,
/// `AlgoSmartAssist`, `VolumeProfile`, `SMCSentinelEngine`) are Swift and
/// non-trivial, and the candle history lives in this app's GRDB store.
/// Exposing them over MCP lets Claude Code, Cursor, or any other MCP
/// client analyse the same market state the chart shows, without porting
/// a line of indicator logic or reaching into the database file.
///
/// Transport: JSON-RPC 2.0 over `POST /mcp`, answered with a single
/// `application/json` body. The spec also allows an SSE response stream;
/// nothing here is long-running or server-initiated, so the simple form
/// is used and `GET /mcp` returns 405 — which clients treat as "this
/// server has no server-to-client stream" and carry on.
///
/// Built on `NWListener` rather than a package: the project's dependency
/// rule is GRDB and swift-markdown-ui only, and an HTTP surface this
/// small (one route, one verb, `Content-Length` bodies) doesn't justify
/// an exception.
///
/// ## Security
///
/// The server binds `127.0.0.1` only, so nothing off this machine can
/// reach it. On top of that it validates the `Origin` header — the
/// defence the MCP spec calls for against DNS-rebinding, where a web
/// page the user is browsing scripts requests at their loopback port —
/// and supports an optional bearer token for when other local user
/// accounts or containers share the host. Read-only by construction:
/// every tool reads candles and computes; none writes to the database,
/// places an order, or touches app state.
final class MCPHTTPServer {

    /// Serialized server state. Every mutation goes through `queue`.
    enum State: Equatable {
        case stopped
        case starting
        case running(port: UInt16)
        case failed(String)

        var isRunning: Bool { if case .running = self { return true }; return false }
    }

    struct Configuration: Equatable {
        var port: UInt16 = 4321
        /// Optional bearer token. Empty means unauthenticated, which is
        /// fine for a single-user machine on loopback.
        var token: String = ""
        var maxBars: Int = 5000
    }

    private let queue = DispatchQueue(label: "com.helix.mcp.server")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var toolbox: MCPToolbox?
    private var configuration = Configuration()

    /// Called on the main queue whenever state changes, so the Settings
    /// card can reflect it without polling.
    var onStateChange: ((State) -> Void)?
    /// Called on the main queue after each handled tool call:
    /// (tool name, success, duration). Drives the activity line in
    /// Settings — the quickest way to tell a silent client from a
    /// misconfigured one.
    var onToolCall: ((String, Bool, TimeInterval) -> Void)?

    private(set) var state: State = .stopped {
        didSet {
            guard state != oldValue else { return }
            let s = state
            DispatchQueue.main.async { self.onStateChange?(s) }
        }
    }

    // MARK: - Lifecycle

    /// Start listening. Idempotent: an already-running server on the same
    /// port is left alone, and a config change restarts it.
    func start(repo: OHLCRepo, configuration config: Configuration) {
        queue.async {
            if case .running(let p) = self.state, p == config.port, self.configuration == config {
                return
            }
            self.stopLocked()
            self.configuration = config
            self.toolbox = MCPToolbox(repo: repo, maxBars: config.maxBars)
            self.state = .starting

            let params = NWParameters.tcp
            // Loopback only. `requiredLocalEndpoint` is what actually
            // constrains the bind — without it NWListener accepts on
            // every interface, which would put the trading data on the
            // local network.
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: config.port)!)
            params.allowLocalEndpointReuse = true

            do {
                let listener = try NWListener(using: params)
                listener.newConnectionHandler = { [weak self] conn in
                    self?.accept(conn)
                }
                listener.stateUpdateHandler = { [weak self] st in
                    guard let self else { return }
                    switch st {
                    case .ready:
                        // Report what the socket actually bound to, not
                        // what was requested — with port 0 the OS picks
                        // one, and a status line naming the wrong port is
                        // worse than none.
                        self.state = .running(port: listener.port?.rawValue ?? config.port)
                    case .failed(let err):
                        self.state = .failed(Self.describe(err, port: config.port))
                        self.queue.async { self.stopLocked() }
                    case .cancelled:
                        if self.state != .stopped, case .failed = self.state {} else { self.state = .stopped }
                    default:
                        break
                    }
                }
                self.listener = listener
                listener.start(queue: self.queue)
            } catch {
                self.state = .failed(Self.describe(error, port: config.port))
            }
        }
    }

    func stop() {
        queue.async {
            self.stopLocked()
            self.state = .stopped
        }
    }

    private func stopLocked() {
        listener?.cancel()
        listener = nil
        for (_, c) in connections { c.cancel() }
        connections.removeAll()
    }

    private static func describe(_ error: Error, port: UInt16) -> String {
        if let nwError = error as? NWError, case .posix(let code) = nwError, code == .EADDRINUSE {
            return "Port \(port) is already in use — another app (or a second copy of Helix) holds it. Pick a different port."
        }
        return error.localizedDescription
    }

    // MARK: - Connection handling

    private func accept(_ conn: NWConnection) {
        let key = ObjectIdentifier(conn)
        connections[key] = conn
        conn.stateUpdateHandler = { [weak self] st in
            switch st {
            case .cancelled, .failed:
                self?.queue.async { self?.connections.removeValue(forKey: key) }
            default:
                break
            }
        }
        conn.start(queue: queue)
        receive(on: conn, buffer: Data())
    }

    /// Read until a complete request (headers + `Content-Length` bytes)
    /// has arrived, answer it, then loop for keep-alive. Bodies are
    /// bounded so a malformed or hostile `Content-Length` can't make the
    /// server buffer without limit.
    private func receive(on conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if error != nil { conn.cancel(); return }

            var buffer = buffer
            if let data { buffer.append(data) }

            if buffer.count > Self.maxRequestBytes {
                self.send(HTTPResponse.plain(status: 413, body: "Request too large"), on: conn, keepAlive: false)
                return
            }

            guard let request = HTTPRequest.parse(buffer) else {
                if isComplete { conn.cancel(); return }
                self.receive(on: conn, buffer: buffer)   // need more bytes
                return
            }

            let response = self.handle(request)
            let keepAlive = request.headers["connection"]?.lowercased() != "close"
            self.send(response, on: conn, keepAlive: keepAlive)

            if keepAlive {
                // Any bytes past this request belong to the next one on a
                // pipelined connection — carry them over rather than
                // dropping them.
                let leftover = buffer.count > request.totalLength
                    ? buffer.suffix(from: request.totalLength)
                    : Data()
                self.receive(on: conn, buffer: Data(leftover))
            }
        }
    }

    private static let maxRequestBytes = 4 * 1024 * 1024

    private func send(_ response: HTTPResponse, on conn: NWConnection, keepAlive: Bool) {
        conn.send(content: response.serialized(keepAlive: keepAlive), completion: .contentProcessed { _ in
            if !keepAlive { conn.cancel() }
        })
    }

    // MARK: - Routing

    private func handle(_ request: HTTPRequest) -> HTTPResponse {
        // CORS preflight — browser-based MCP clients send one before the
        // POST. Answered permissively for methods/headers but the Origin
        // check below still gates the real request.
        if request.method == "OPTIONS" {
            return HTTPResponse(
                status: 204,
                headers: [
                    "Access-Control-Allow-Origin": "*",
                    "Access-Control-Allow-Methods": "POST, GET, OPTIONS",
                    "Access-Control-Allow-Headers": "Content-Type, Authorization, Mcp-Session-Id, MCP-Protocol-Version",
                ],
                body: Data()
            )
        }

        // DNS-rebinding guard. A page at evil.com can script requests to
        // 127.0.0.1, and the browser will happily send them — but it
        // stamps the real Origin, and a genuine MCP client sends either
        // none or a loopback one.
        if let origin = request.headers["origin"], !Self.isAllowedOrigin(origin) {
            return HTTPResponse.plain(status: 403, body: "Forbidden origin: \(origin)")
        }

        if !configuration.token.isEmpty {
            let presented = request.headers["authorization"]?
                .replacingOccurrences(of: "Bearer ", with: "")
                .trimmingCharacters(in: .whitespaces) ?? ""
            // Constant-time compare — the token is low-value, but a
            // length-and-prefix-leaking compare on a network path is a
            // bad habit to keep.
            guard Self.constantTimeEquals(presented, configuration.token) else {
                return HTTPResponse(
                    status: 401,
                    headers: ["WWW-Authenticate": "Bearer", "Content-Type": "text/plain"],
                    body: Data("Unauthorized".utf8)
                )
            }
        }

        switch (request.method, request.path) {
        case ("GET", "/health"):
            return HTTPResponse.json(.object([
                "status": .string("ok"),
                "server": .string(MCP.serverName),
                "version": .string(MCP.serverVersion),
                "protocol": .string(MCP.protocolVersion),
                "tools": .number(Double(toolbox?.tools.count ?? 0)),
            ]))

        case ("POST", "/mcp"), ("POST", "/"):
            return handleRPC(request.body)

        case ("GET", "/mcp"):
            // No server-initiated stream. 405 is the spec's sanctioned
            // way to say so; clients fall back to POST-only.
            return HTTPResponse.plain(status: 405, body: "This server does not offer an SSE stream; POST JSON-RPC to /mcp.")

        default:
            return HTTPResponse.plain(status: 404, body: "Not found")
        }
    }

    private static func isAllowedOrigin(_ origin: String) -> Bool {
        guard let url = URL(string: origin), let host = url.host else {
            // "null" (file:// pages, sandboxed iframes) and unparseable
            // values are not loopback — reject.
            return false
        }
        return host == "127.0.0.1" || host == "localhost" || host == "::1" || host == "[::1]"
    }

    private static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }

    // MARK: - JSON-RPC dispatch

    private func handleRPC(_ body: Data) -> HTTPResponse {
        // Batches are legal JSON-RPC and some clients send them.
        if let array = try? JSONDecoder().decode([JSONRPCRequest].self, from: body), !array.isEmpty {
            let responses = array.compactMap { dispatch($0)?.json }
            // An all-notification batch gets 202 with no body.
            return responses.isEmpty ? HTTPResponse(status: 202, headers: [:], body: Data())
                                     : HTTPResponse.json(.array(responses))
        }

        guard let request = try? JSONDecoder().decode(JSONRPCRequest.self, from: body) else {
            return HTTPResponse.json(JSONRPCResponse.failure(id: nil, error: .parseError()).json, status: 400)
        }
        guard let response = dispatch(request) else {
            // Notification — the spec requires no body.
            return HTTPResponse(status: 202, headers: [:], body: Data())
        }
        return HTTPResponse.json(response.json)
    }

    /// Returns nil for notifications (no `id`), which must go unanswered.
    private func dispatch(_ request: JSONRPCRequest) -> JSONRPCResponse? {
        guard let id = request.id else { return nil }

        do {
            let result = try route(method: request.method, params: request.params)
            return .success(id: id, result: result)
        } catch let error as JSONRPCError {
            return .failure(id: id, error: error)
        } catch {
            return .failure(id: id, error: .internalError(error.localizedDescription))
        }
    }

    private func route(method: String, params: JSONValue?) throws -> JSONValue {
        switch method {
        case "initialize":
            return .object([
                "protocolVersion": .string(MCP.protocolVersion),
                "capabilities": .object([
                    // `listChanged: false` — the tool set is fixed at
                    // compile time, so clients can cache it.
                    "tools": .object(["listChanged": .bool(false)]),
                ]),
                "serverInfo": .object([
                    "name": .string(MCP.serverName),
                    "title": .string("Helix Trading"),
                    "version": .string(MCP.serverVersion),
                ]),
                "instructions": .string("""
                Market-structure tools over the Helix Trading app's own \
                candle store and indicator engines. Symbols and \
                timeframes come from list_symbols. For a full Smart-Money \
                read on a symbol call smc_brief — it bundles ranked order \
                blocks, ALGOSMART structure and previous-day levels \
                across two timeframes in one consistent snapshot. Use the \
                individual tools when you want one piece. All tools are \
                read-only; nothing here places or modifies a trade.
                """),
            ])

        case "ping":
            return .object([:])

        case "tools/list":
            guard let toolbox else { throw JSONRPCError.internalError("Server not ready") }
            return .object(["tools": .array(toolbox.tools.map(\.listing))])

        case "tools/call":
            return try callTool(params)

        case "resources/list":
            return .object(["resources": .array([])])

        case "prompts/list":
            return .object(["prompts": .array([])])

        default:
            throw JSONRPCError.methodNotFound(method)
        }
    }

    private func callTool(_ params: JSONValue?) throws -> JSONValue {
        guard let toolbox else { throw JSONRPCError.internalError("Server not ready") }
        guard let name = params?["name"]?.stringValue else {
            throw JSONRPCError.invalidParams("`name` is required")
        }
        guard let tool = toolbox.tool(named: name) else {
            throw JSONRPCError.invalidParams(
                "Unknown tool \"\(name)\". Available: \(toolbox.tools.map(\.name).joined(separator: ", "))."
            )
        }
        let args = params?["arguments"]?.objectValue ?? [:]

        let started = Date()
        do {
            let result = try tool.run(args)
            report(name, true, started)
            return Self.toolResult(result, isError: false)
        } catch let error as JSONRPCError {
            report(name, false, started)
            // Tool failures are reported *inside* the result with
            // `isError`, not as a JSON-RPC error: the spec reserves
            // protocol errors for protocol problems, and this way the
            // model sees the message and can correct its arguments
            // instead of the client swallowing it as a transport fault.
            return Self.toolResult(.object(["error": .string(error.message)]), isError: true)
        } catch {
            report(name, false, started)
            return Self.toolResult(.object(["error": .string(error.localizedDescription)]), isError: true)
        }
    }

    private func report(_ name: String, _ ok: Bool, _ started: Date) {
        let elapsed = Date().timeIntervalSince(started)
        DispatchQueue.main.async { self.onToolCall?(name, ok, elapsed) }
    }

    /// Wrap a payload in MCP's tool-result envelope.
    ///
    /// Both forms are populated: `structuredContent` for clients that
    /// consume JSON directly, and the same JSON pretty-printed into a
    /// text block for those that only read `content` — which most models
    /// still do.
    private static func toolResult(_ payload: JSONValue, isError: Bool) -> JSONValue {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let text = (try? encoder.encode(payload)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return .object([
            "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
            "structuredContent": payload,
            "isError": .bool(isError),
        ])
    }
}

// MARK: - Minimal HTTP

/// Just enough HTTP/1.1 to carry JSON-RPC: request line, headers, and a
/// `Content-Length` body. No chunked encoding — MCP clients don't use it
/// for requests.
private struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]   // lowercased keys
    let body: Data
    /// Bytes this request occupies, so a pipelined connection can find
    /// where the next one begins.
    let totalLength: Int

    static func parse(_ buffer: Data) -> HTTPRequest? {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let headerText = String(data: buffer[..<headerEnd.lowerBound], encoding: .utf8) else { return nil }

        var lines = headerText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        let bodyStart = headerEnd.upperBound
        let contentLength = headers["content-length"].flatMap { Int($0) } ?? 0
        let available = buffer.distance(from: bodyStart, to: buffer.endIndex)
        guard available >= contentLength else { return nil }   // body still arriving

        let bodyEnd = buffer.index(bodyStart, offsetBy: contentLength)
        // Strip the query string — no route here reads one, and leaving
        // it on would break exact-match routing for clients that append
        // cache-busting parameters.
        let rawPath = String(requestLine[1])
        let path = rawPath.split(separator: "?", maxSplits: 1).first.map(String.init) ?? rawPath

        return HTTPRequest(
            method: String(requestLine[0]).uppercased(),
            path: path,
            headers: headers,
            body: Data(buffer[bodyStart..<bodyEnd]),
            totalLength: buffer.distance(from: buffer.startIndex, to: bodyEnd)
        )
    }
}

private struct HTTPResponse {
    var status: Int
    var headers: [String: String]
    var body: Data

    static func plain(status: Int, body: String) -> HTTPResponse {
        HTTPResponse(status: status, headers: ["Content-Type": "text/plain; charset=utf-8"], body: Data(body.utf8))
    }

    static func json(_ value: JSONValue, status: Int = 200) -> HTTPResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = (try? encoder.encode(value)) ?? Data("{}".utf8)
        return HTTPResponse(
            status: status,
            headers: ["Content-Type": "application/json; charset=utf-8"],
            body: data
        )
    }

    func serialized(keepAlive: Bool) -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        var allHeaders = headers
        allHeaders["Content-Length"] = String(body.count)
        allHeaders["Connection"] = keepAlive ? "keep-alive" : "close"
        // Loopback-only server, and the Origin check above is the real
        // gate; this just stops browser clients failing on the preflight.
        allHeaders["Access-Control-Allow-Origin"] = "*"
        for (k, v) in allHeaders.sorted(by: { $0.key < $1.key }) {
            head += "\(k): \(v)\r\n"
        }
        head += "\r\n"
        var out = Data(head.utf8)
        out.append(body)
        return out
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 202: return "Accepted"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 413: return "Payload Too Large"
        default:  return "Internal Server Error"
        }
    }
}
