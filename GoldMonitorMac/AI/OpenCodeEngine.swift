import Foundation

/// Streams an analysis from the local `opencode` CLI or a remote
/// OpenCode server. Supports two modes:
///
/// - **Local CLI**: Spawns the CLI as a child `Process` (existing behavior)
/// - **Remote server**: Connects to `opencode serve` / `opencode web`
///   via HTTP API with optional basic auth
///
/// The mode is controlled by the `ai.opencode.useRemote` UserDefaults
/// key. When remote mode is enabled, the server URL and password are
/// read from UserDefaults and Keychain respectively.
struct OpenCodeEngine: AIEngine {
    let label = "OpenCode"

    /// Maximum time (in seconds) to wait for the process to produce
    /// any output before declaring a timeout.  OpenCode is a full
    /// agent — if the model tries to call a tool and the process
    /// blocks, we need to bail rather than hang forever.
    static let stallTimeoutSeconds: TimeInterval = 120

    var isAvailable: Bool {
        if Self.isRemoteMode {
            return Self.remoteServerURL != nil
        }
        return Self.locateBinary() != nil
    }

    var availability: EngineAvailability {
        if isAvailable { return .ready }
        if Self.isRemoteMode {
            return .notReady(hint: "OpenCode server URL not configured. Set it in Settings → AI → OpenCode.")
        }
        return .notReady(hint: "OpenCode CLI not found. Install with `curl -fsSL https://opencode.ai/install | bash`, then restart Helix Trading.")
    }

    func run(system: String, user: String) -> AsyncThrowingStream<AIStreamEvent, Error> {
        if Self.isRemoteMode {
            return runRemote(system: system, user: user)
        }
        return runLocal(system: system, user: user)
    }

    // MARK: - Remote Mode Configuration

    /// Whether remote server mode is enabled.
    static var isRemoteMode: Bool {
        UserDefaults.standard.bool(forKey: "ai.opencode.useRemote")
    }

    /// The remote server URL (e.g., "http://192.168.1.100:4096").
    static var remoteServerURL: String? {
        let url = UserDefaults.standard.string(forKey: "ai.opencode.serverURL") ?? ""
        return url.isEmpty ? nil : url
    }

    /// The remote server password from Keychain.
    static var remoteServerPassword: String? {
        KeychainHelper.get(.opencodeServerPass)
    }

    // MARK: - Remote HTTP Engine

    private func runRemote(system: String, user: String) -> AsyncThrowingStream<AIStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            guard let baseURL = Self.remoteServerURL,
                  let serverURL = URL(string: baseURL) else {
                continuation.finish(throwing: OpenCodeError.remoteServerNotConfigured)
                return
            }

            let model = UserDefaults.standard.string(forKey: "ai.opencode.model")
                ?? OpenCodeModelCatalog.defaultModelID

            let fullPrompt = "\(system)\n\n---\n\n\(user)"
            let task = Task { @Sendable in
                do {
                    let session = try await RemoteOpenCodeSession(
                        serverURL: serverURL,
                        password: Self.remoteServerPassword
                    )

                    try await session.run(
                        prompt: fullPrompt,
                        model: model,
                        continuation: continuation
                    )

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    // MARK: - Local CLI Engine

    private func runLocal(system: String, user: String) -> AsyncThrowingStream<AIStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            guard let binary = Self.locateBinary() else {
                continuation.finish(throwing: OpenCodeError.notInstalled)
                return
            }

            let model = UserDefaults.standard.string(forKey: "ai.opencode.model")
                ?? OpenCodeModelCatalog.defaultModelID

            let fullPrompt = "\(system)\n\n---\n\n\(user)"

            let workspace = Self.prepareWorkspace()

            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.currentDirectoryURL = workspace

            let modelArg = model.hasPrefix("opencode/") ? model : "opencode/\(model)"

            // Build arguments.
            // - `run`             : non-interactive one-shot mode
            // - `--format json`   : raw JSON event stream (NDJSON)
            // - `--print-logs`    : REQUIRED — without this flag,
            //                       `--format json` produces zero
            //                       stdout output (the JSON events
            //                       are swallowed by the internal
            //                       logger). Logs go to stderr.
            // - `--dir <path>`    : force OpenCode to use our empty
            //                       workspace as the project root.
            //                       Without this, OpenCode walks up
            //                       from cwd to find a git root and
            //                       initializes the real project
            //                       (file watcher, git snapshot, …)
            //                       which blocks JSON output.
            // - `--auto`          : auto-approve tool calls so the
            //                       agent never blocks waiting for
            //                       interactive approval
            // - `--thinking`      : surface reasoning blocks
            // - `-m <model>`      : model selection
            // The prompt is passed as the positional `message` arg.
            process.arguments = [
                "run",
                "--format", "json",
                "--print-logs",
                "--dir", workspace.path,
                "--auto",
                "--thinking",
                "-m", modelArg,
                fullPrompt,
            ]

            var env = ProcessInfo.processInfo.environment
            if let apiKey = KeychainHelper.get(.opencodeAPIKey), !apiKey.isEmpty {
                env["OPENCODE_API_KEY"] = apiKey
            }
            process.environment = env

            let stdinPipe = Pipe()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardInput = stdinPipe
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            continuation.onTermination = { _ in
                if process.isRunning { process.terminate() }
            }

            do {
                try process.run()
            } catch {
                continuation.finish(throwing: OpenCodeError.spawn(error.localizedDescription))
                return
            }

            // Close stdin immediately — opencode doesn't read from it.
            try? stdinPipe.fileHandleForWriting.close()

            let parser = OpenCodeStreamParser()

            var stderrData = Data()
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                } else {
                    stderrData.append(data)
                }
            }

            // Read stdout in a background task using a synchronous
            // loop.  This avoids the `readabilityHandler` +
            // `waitUntilExit()` deadlock that occurs when OpenCode
            // spawns child processes (the handler blocks on
            // waitUntilExit while the child holds the pipe open).
            // The loop naturally terminates when the pipe closes
            // (availableData returns empty after the process exits).
            let stdoutHandle = stdoutPipe.fileHandleForReading
            let readQueue = DispatchQueue(label: "opencode.stdout.reader", qos: .userInitiated)
            readQueue.async {
                var lastActivity = Date()
                var timedOut = false

                // Stall-detection timer.
                let stallTimer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
                stallTimer.schedule(deadline: .now() + .seconds(5), repeating: .seconds(5))
                stallTimer.setEventHandler {
                    if Date().timeIntervalSince(lastActivity) > Self.stallTimeoutSeconds {
                        timedOut = true
                        stallTimer.cancel()
                        if process.isRunning { process.terminate() }
                    }
                }
                stallTimer.resume()

                while true {
                    let data = stdoutHandle.availableData
                    if data.isEmpty {
                        // Pipe closed — process exited.
                        stallTimer.cancel()
                        for event in parser.drain() { continuation.yield(event) }
                        break
                    }
                    lastActivity = Date()
                    for event in parser.consume(data) { continuation.yield(event) }
                }

                // Give the process a moment to fully exit.
                process.waitUntilExit()

                if timedOut {
                    continuation.finish(throwing: OpenCodeError.timeout)
                } else if let message = parser.capturedError {
                    continuation.finish(throwing: OpenCodeError.runtime(message))
                } else if process.terminationStatus != 0 {
                    let err = String(data: stderrData, encoding: .utf8) ?? ""
                    let stderr = err.trimmingCharacters(in: .whitespacesAndNewlines)
                    if process.terminationStatus == 143 || process.terminationStatus == 15 {
                        if !parser.hadAnyOutput {
                            continuation.finish(throwing: OpenCodeError.runtime("OpenCode was terminated (no output received)."))
                        } else {
                            continuation.finish()
                        }
                    } else {
                        continuation.finish(throwing: OpenCodeError.exit(
                            code: process.terminationStatus,
                            stderr: stderr
                        ))
                    }
                } else {
                    continuation.finish()
                }
            }
        }
    }

    // MARK: - Workspace

    private static func prepareWorkspace() -> URL {
        let fm = FileManager.default
        let base = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        let workspace = base
            .appendingPathComponent("HelixTrading", isDirectory: true)
            .appendingPathComponent("opencode-workspace", isDirectory: true)
        try? fm.createDirectory(at: workspace, withIntermediateDirectories: true)
        return workspace
    }

    // MARK: - Binary location

    static func locateBinary() -> String? {
        var candidates = [
            "/opt/homebrew/bin/opencode",
            "/usr/local/bin/opencode",
            NSHomeDirectory() + "/.local/bin/opencode",
            NSHomeDirectory() + "/.npm-global/bin/opencode",
            NSHomeDirectory() + "/.bun/bin/opencode",
        ]
        if let custom = ProcessInfo.processInfo.environment["OPENCODE_BIN"], !custom.isEmpty {
            candidates.insert(custom, at: 0)
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

// MARK: - Remote OpenCode Session

/// Handles communication with a remote OpenCode server via HTTP API.
/// Creates a session, sends a prompt, and streams the response.
private final class RemoteOpenCodeSession: Sendable {
    let serverURL: URL
    let sessionID: String
    private let authorizationHeader: String?
    private let urlSession: URLSession

    init(serverURL: URL, password: String?) async throws {
        self.serverURL = serverURL

        // Configure basic auth if password is provided
        if let password = password, !password.isEmpty {
            let credentials = "opencode:\(password)"
            let base64 = Data(credentials.utf8).base64EncodedString()
            self.authorizationHeader = "Basic \(base64)"
        } else {
            self.authorizationHeader = nil
        }

        // Configure URLSession with reasonable timeouts
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 600
        self.urlSession = URLSession(configuration: config)

        // Create a session on the remote server
        self.sessionID = try await Self.createSession(
            serverURL: serverURL,
            authorization: authorizationHeader,
            urlSession: urlSession
        )
    }

    /// Create a new session on the remote server.
    private static func createSession(
        serverURL: URL,
        authorization: String?,
        urlSession: URLSession
    ) async throws -> String {
        let url = serverURL.appendingPathComponent("session")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let auth = authorization {
            request.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "title": "Helix Trading Analysis"
        ])

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenCodeError.remoteSessionCreateFailed
        }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OpenCodeError.runtime("Session creation failed (HTTP \(http.statusCode)): \(body.prefix(200))")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? String else {
            throw OpenCodeError.remoteSessionCreateFailed
        }

        return id
    }

    /// Send a prompt and stream the response via server-sent events.
    @Sendable
    func run(
        prompt: String,
        model: String,
        continuation: AsyncThrowingStream<AIStreamEvent, Error>.Continuation
    ) async throws {
        // Send the prompt asynchronously (returns 204 No Content)
        let messageURL = serverURL
            .appendingPathComponent("session")
            .appendingPathComponent(sessionID)
            .appendingPathComponent("prompt_async")

        var messageRequest = URLRequest(url: messageURL)
        messageRequest.httpMethod = "POST"
        messageRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let auth = authorizationHeader {
            messageRequest.setValue(auth, forHTTPHeaderField: "Authorization")
        }

        // Parse model into provider/modelID.  The server expects
        // { providerID, modelID } — NOT a flat string.
        // Free models live on the "opencode" provider; paid models
        // on "opencode-go".  If the model string already contains
        // a slash, respect it verbatim.
        let providerID: String
        let modelID: String
        if model.contains("/") {
            let parts = model.split(separator: "/", maxSplits: 1)
            providerID = String(parts[0])
            modelID = String(parts[1])
        } else {
            // Look up whether the model is free or paid from the
            // catalog so we route to the correct server provider.
            let isFree = OpenCodeModelCatalog.allModels.first { $0.id == model }?.isFree ?? true
            providerID = isFree ? "opencode" : "opencode-go"
            modelID = model
        }

        messageRequest.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": ["providerID": providerID, "modelID": modelID],
            "parts": [["type": "text", "text": prompt]],
        ])

        let (msgData, msgResponse) = try await urlSession.data(for: messageRequest)
        guard let msgHTTP = msgResponse as? HTTPURLResponse else {
            throw OpenCodeError.remoteMessageFailed
        }
        guard (200...299).contains(msgHTTP.statusCode) else {
            let body = String(data: msgData, encoding: .utf8) ?? ""
            throw OpenCodeError.remoteMessageDetail(msgHTTP.statusCode, body)
        }

        // Subscribe to server-sent events to stream the response
        let eventURL = serverURL.appendingPathComponent("event")
        var eventRequest = URLRequest(url: eventURL)
        eventRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let auth = authorizationHeader {
            eventRequest.setValue(auth, forHTTPHeaderField: "Authorization")
        }

        let (bytes, _) = try await urlSession.bytes(for: eventRequest)

        var textAccumulator: [String: String] = [:]
        var lineBuffer = ""

        for try await byte in bytes {
            if Task.isCancelled { break }

            let char = Character(UnicodeScalar(byte))
            if char == "\n" {
                let trimmed = lineBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                lineBuffer = ""

                guard !trimmed.isEmpty else { continue }

                // Parse SSE data fields
                if trimmed.hasPrefix("data:") {
                    let dataStr = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)

                    guard let jsonData = dataStr.data(using: .utf8),
                          let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
                    else { continue }

                    // Check if this event is for our session.
                    // The server may put sessionID at the top level
                    // or nested inside properties.
                    let eventSessionID = (obj["sessionID"] as? String)
                        ?? ((obj["properties"] as? [String: Any])?["sessionID"] as? String)
                    if let esid = eventSessionID, esid != sessionID { continue }

                    // Handle different event types.
                    // Server sends { type, properties } format.
                    let eventType = (obj["type"] as? String)
                                ?? (obj["kind"] as? String)
                                ?? ""
                    switch eventType {
                    case "message.part.delta":
                        // Streaming delta — properties has { field, delta, partID }.
                        // field is "text" or "reasoning", delta is the incremental text.
                        if let info = obj["properties"] as? [String: Any],
                           let field = info["field"] as? String,
                           let delta = info["delta"] as? String,
                           !delta.isEmpty {
                            if field == "reasoning" {
                                continuation.yield(.thinking(delta))
                            } else {
                                continuation.yield(.text(delta))
                            }
                        }

                    case "part.created", "part.updated",
                         "message.part.updated":
                        // Cumulative update — properties has { part: { type, text, id } }.
                        // Use diff to extract only new text.
                        if let info = obj["properties"] as? [String: Any],
                           let part = info["part"] as? [String: Any] {
                            let partType = part["type"] as? String ?? ""
                            let partID = part["id"] as? String ?? ""
                            let text = part["text"] as? String ?? ""

                            guard !text.isEmpty else { continue }

                            switch partType {
                            case "text":
                                if let delta = diff(id: "remote-\(partID)", against: text, store: &textAccumulator) {
                                    continuation.yield(.text(delta))
                                }
                            case "reasoning":
                                if let delta = diff(id: "remote-reasoning-\(partID)", against: text, store: &textAccumulator) {
                                    continuation.yield(.thinking(delta))
                                }
                            default:
                                break
                            }
                        }

                    case "session.status", "session.updated", "session.idle":
                        if let info = obj["properties"] as? [String: Any],
                           let status = info["status"] as? String {
                            if status == "completed" || status == "failed" || status == "idle" {
                                return
                            }
                        }
                        if eventType == "session.idle" {
                            return
                        }

                    default:
                        break
                    }
                }
            } else {
                lineBuffer.append(char)
            }
        }
    }

    /// Per-part suffix diff for streaming. Yields only the new text
    /// since the last chunk.
    private func diff(id: String, against new: String, store: inout [String: String]) -> String? {
        let prev = store[id] ?? ""
        if new == prev { return nil }
        if new.hasPrefix(prev) {
            let added = String(new.dropFirst(prev.count))
            store[id] = new
            return added.isEmpty ? nil : added
        }
        store[id] = new
        return new
    }
}

// MARK: - NDJSON Stream Parser (Local CLI)

/// Converts the `opencode run --format json` event stream into
/// `AIStreamEvent`s.
///
/// Actual OpenCode event shapes (verified from CLI v1.17):
///
///   {"type":"step_start","part":{…}}
///   {"type":"reasoning","part":{"text":"The user wants…"}}
///   {"type":"text","part":{"text":"Hello"}}
///   {"type":"step_finish","part":{…},"tokens":{…},"cost":0}
///
/// Text lives under `part.text`, NOT at the top level. Each event is
/// a complete snapshot (not a delta) so we diff per-part-id to yield
/// only the new suffix.
private final class OpenCodeStreamParser {
    private var lineBuffer = Data()
    private var yieldedByID: [String: String] = [:]
    private(set) var capturedError: String?
    /// Tracks whether we ever received any text or thinking content.
    /// Used by the engine to distinguish "stalled with no output"
    /// from "completed normally".
    private(set) var hadAnyOutput = false

    func consume(_ data: Data) -> [AIStreamEvent] {
        lineBuffer.append(data)
        var out: [AIStreamEvent] = []
        while let nl = lineBuffer.firstIndex(of: 0x0a) {
            let line = Data(lineBuffer.prefix(nl))
            lineBuffer.removeSubrange(0...nl)
            out.append(contentsOf: parseLine(line))
        }
        return out
    }

    func drain() -> [AIStreamEvent] {
        guard !lineBuffer.isEmpty else { return [] }
        let line = lineBuffer
        lineBuffer.removeAll()
        return parseLine(line)
    }

    private func parseLine(_ data: Data) -> [AIStreamEvent] {
        guard !data.isEmpty,
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return [] }

        guard let type = obj["type"] as? String else { return [] }

        switch type {
        case "text", "content":
            let part = obj["part"] as? [String: Any]
            let id = (part?["id"] as? String) ?? "text"
            let text = (part?["text"] as? String) ?? (obj["text"] as? String) ?? ""
            guard !text.isEmpty, let delta = diff(id: id, against: text) else { return [] }
            hadAnyOutput = true
            return [.text(delta)]

        case "reasoning", "thinking":
            let part = obj["part"] as? [String: Any]
            let id = (part?["id"] as? String) ?? "reasoning"
            let text = (part?["text"] as? String) ?? (obj["text"] as? String) ?? ""
            guard !text.isEmpty, let delta = diff(id: id, against: text) else { return [] }
            hadAnyOutput = true
            return [.thinking(delta)]

        case "step_finish", "finish", "done", "end":
            // Completion signal — nothing to yield, but we note it
            // so the engine knows the agent finished cleanly.
            return []

        case "error", "stream_error":
            if let errObj = obj["error"] as? [String: Any] {
                if let data = errObj["data"] as? [String: Any],
                   let msg = data["message"] as? String {
                    capturedError = msg
                } else if let name = errObj["name"] as? String {
                    capturedError = name
                } else if let msg = errObj["message"] as? String {
                    capturedError = msg
                }
            } else if let msg = obj["message"] as? String {
                capturedError = msg
            } else if let errorStr = obj["error"] as? String {
                capturedError = errorStr
            } else {
                capturedError = "Unknown OpenCode error"
            }
            return []

        default:
            // step_start, tool_use, tool_result, session, etc.
            // — silently ignore.
            return []
        }
    }

    private func diff(id: String, against new: String) -> String? {
        let prev = yieldedByID[id] ?? ""
        if new == prev { return nil }
        if new.hasPrefix(prev) {
            let added = String(new.dropFirst(prev.count))
            yieldedByID[id] = new
            return added.isEmpty ? nil : added
        }
        yieldedByID[id] = new
        return new
    }
}

// MARK: - Errors

enum OpenCodeError: LocalizedError {
    case notInstalled
    case spawn(String)
    case runtime(String)
    case exit(code: Int32, stderr: String)
    case timeout
    case remoteServerNotConfigured
    case remoteSessionCreateFailed
    case remoteMessageFailed
    case remoteMessageDetail(Int, String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "OpenCode CLI not found. Install with `curl -fsSL https://opencode.ai/install | bash`, then restart Helix Trading."
        case .spawn(let msg):
            return "OpenCode spawn failed: \(msg)"
        case .runtime(let msg):
            if msg.lowercased().contains("api key") || msg.lowercased().contains("auth") {
                return "\(msg)\n\nSet your API key in Settings → AI → OpenCode, or run `opencode auth login` in your terminal."
            }
            return msg
        case .exit(let code, let stderr):
            return stderr.isEmpty
                ? "OpenCode exited with code \(code). Run `opencode run \"hello\"` in your terminal to diagnose."
                : "OpenCode error: \(stderr)"
        case .timeout:
            return "OpenCode timed out — no output received for \(Int(OpenCodeEngine.stallTimeoutSeconds))s. The model may be stuck on a tool call or extended thinking."
        case .remoteServerNotConfigured:
            return "OpenCode server URL not configured. Set it in Settings → AI → OpenCode."
        case .remoteSessionCreateFailed:
            return "Failed to create session on the remote OpenCode server. Check the server URL and password in Settings."
        case .remoteMessageFailed:
            return "Failed to send message to the remote OpenCode server. Check the server is running and accessible."
        case .remoteMessageDetail(let code, let body):
            let preview = body.prefix(200)
            return "OpenCode server returned HTTP \(code): \(preview)"
        }
    }
}
