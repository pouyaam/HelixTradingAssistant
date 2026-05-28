import Foundation

/// Streams an analysis from the local `codex` CLI. Same binary the user
/// already runs from their terminal — no API key, uses their ChatGPT /
/// Codex session via the CLI's own auth (`codex login`).
///
/// Approach mirrors `ClaudeEngine`: spawn the CLI as a child Process in
/// non-interactive `exec` mode, write the prompt on stdin, and parse the
/// `--json` Thread-Events stream off stdout into `AIStreamEvent`s. The
/// CLI emits one JSON object per line; we route `agent_message` items to
/// `.text` and `reasoning` items to `.thinking`, so the analysis page
/// shows the same "Thinking → Output" split it does for Claude.
///
/// Model + reasoning effort come from the same `@AppStorage`-backed
/// UserDefaults keys the Settings page writes (`ai.codex.model`,
/// `ai.codex.effort`), exactly like the Claude engine.
struct CodexEngine: AIEngine {
    let label = "Codex"

    /// Available whenever the binary resolves on $PATH / the known
    /// install locations. (Auth is checked lazily — a logged-out CLI
    /// surfaces its own "please sign in" error in the stream, which we
    /// pass through verbatim so the user knows to run `codex login`.)
    var isAvailable: Bool { Self.locateBinary() != nil }

    var availability: EngineAvailability {
        if isAvailable { return .ready }
        return .notReady(hint: "Codex CLI not found. Install with `npm i -g @openai/codex` (or `brew install codex`), then restart Helix Trading.")
    }

    func run(system: String, user: String) -> AsyncThrowingStream<AIStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            guard let binary = Self.locateBinary() else {
                continuation.finish(throwing: CodexError.notInstalled)
                return
            }

            // Same UserDefaults keys the Settings page writes. Codex
            // takes the model via `-m` and reasoning effort via a
            // config override (`model_reasoning_effort`), so unlike
            // Claude we don't need to inline an effort hint into the
            // prompt — the CLI wires it natively.
            let model = UserDefaults.standard.string(forKey: "ai.codex.model")
                ?? "gpt-5.5"
            let effort = UserDefaults.standard.string(forKey: "ai.codex.effort")
                ?? "high"

            // Codex `exec` has no separate system field — inline both
            // with a delimiter so the model still reads the analyst
            // framing up front and the task body below. Matches the
            // Claude engine's approach.
            let fullPrompt = """
            \(system)

            ---

            \(user)
            """

            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.currentDirectoryURL = Self.prepareWorkspace()

            // `exec` runs one prompt non-interactively and exits.
            //   --json                 emit Thread-Events JSONL on stdout
            //   --skip-git-repo-check  workspace isn't a git repo
            //   --sandbox read-only    analysis never needs to write/run;
            //                          keeps a stray model command harmless
            //   -c approval_policy=never  fully non-interactive — never
            //                          block waiting for an approval
            //   -c mcp_servers={}      disable the user's configured MCP
            //                          servers (figma/gold/etc.) so each
            //                          run is fast + deterministic and we
            //                          don't pay their startup/connect cost
            //   -c model_reasoning_effort  native effort control
            //   -m <model>             model variant from Settings
            //   -                      read the prompt from stdin
            process.arguments = [
                "exec",
                "--json",
                "--skip-git-repo-check",
                "--sandbox", "read-only",
                "-c", "approval_policy=\"never\"",
                "-c", "mcp_servers={}",
                "-c", "model_reasoning_effort=\"\(effort)\"",
                "-m", model,
                "-",
            ]

            // Inherit the parent environment so the CLI finds its
            // CODEX_HOME / auth + any PATH the user's shell set up.
            process.environment = ProcessInfo.processInfo.environment

            let stdinPipe = Pipe()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardInput = stdinPipe
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            // Cancellation: when the consumer stops iterating (Stop
            // button, page dismiss), kill the child so it doesn't keep
            // burning quota.
            continuation.onTermination = { _ in
                if process.isRunning { process.terminate() }
            }

            do {
                try process.run()
            } catch {
                continuation.finish(throwing: CodexError.spawn(error.localizedDescription))
                return
            }

            // Write the prompt to stdin and close — `codex exec -`
            // reads the prompt from stdin until EOF.
            if let data = fullPrompt.data(using: .utf8) {
                stdinPipe.fileHandleForWriting.write(data)
            }
            try? stdinPipe.fileHandleForWriting.close()

            let parser = CodexStreamParser()

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    // Flush any trailing partial line.
                    for event in parser.drain() { continuation.yield(event) }
                    process.waitUntilExit()

                    // A structured error event (turn.failed / error)
                    // takes priority — it carries the real reason
                    // (e.g. expired auth) regardless of exit code.
                    if let message = parser.capturedError {
                        continuation.finish(throwing: CodexError.runtime(message))
                        return
                    }
                    if process.terminationStatus != 0 {
                        let err = String(
                            data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
                            encoding: .utf8
                        ) ?? ""
                        continuation.finish(throwing: CodexError.exit(
                            code: process.terminationStatus,
                            stderr: err.trimmingCharacters(in: .whitespacesAndNewlines)
                        ))
                    } else {
                        continuation.finish()
                    }
                    return
                }
                for event in parser.consume(data) { continuation.yield(event) }
            }
        }
    }

    // ── Workspace ──────────────────────────────────────────────────
    /// A stable, app-owned working directory for the CLI. Codex wants
    /// a directory to anchor its session; we give it a Helix-scoped
    /// folder under Application Support (alongside the Claude
    /// workspace) so "wipe Helix data" sweeps it too. `read-only`
    /// sandbox means nothing actually gets written here during an
    /// analysis.
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
            .appendingPathComponent("codex-workspace", isDirectory: true)
        try? fm.createDirectory(at: workspace, withIntermediateDirectories: true)
        return workspace
    }

    // ── Binary location ────────────────────────────────────────────
    /// Find `codex` in the typical install locations. Avoid `which` to
    /// skip a subprocess on every availability check; the small static
    /// list covers Homebrew, npm-global, and explicit ~/.local installs.
    /// Honours `CODEX_BIN` for unusual setups.
    static func locateBinary() -> String? {
        var candidates = [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            NSHomeDirectory() + "/.local/bin/codex",
            NSHomeDirectory() + "/.npm-global/bin/codex",
        ]
        if let custom = ProcessInfo.processInfo.environment["CODEX_BIN"], !custom.isEmpty {
            candidates.insert(custom, at: 0)
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

// MARK: - Thread-Events JSONL parser

/// Converts the `codex exec --json` Thread-Events stream into
/// `AIStreamEvent`s. The stream is newline-delimited JSON; relevant
/// shapes:
///
///   {"type":"thread.started","thread_id":"…"}
///   {"type":"turn.started"}
///   {"type":"item.started","item":{"id":"…","item_type":"reasoning", …}}
///   {"type":"item.updated","item":{"id":"…","item_type":"reasoning","text":"…"}}
///   {"type":"item.completed","item":{"id":"…","item_type":"agent_message","text":"…"}}
///   {"type":"turn.completed","usage":{…}}
///   {"type":"turn.failed","error":{"message":"…"}}
///   {"type":"error","message":"…"}
///
/// `item.updated` / `item.completed` carry the item's *full* text
/// snapshot (not a delta), so we track per-item-id how much we've
/// already emitted and yield only the new suffix — this gives true
/// incremental streaming when the CLI sends progressive snapshots,
/// and degrades to a single emit when it only sends the completed
/// item. The CLI also interleaves non-JSON log lines (timestamped
/// ERROR traces); those fail JSON parsing and are skipped.
private final class CodexStreamParser {
    private var lineBuffer = Data()
    /// Per-item accumulated text we've already emitted, keyed by the
    /// item's id. Lets reasoning + message items diff independently.
    private var yieldedByItem: [String: String] = [:]
    /// Last structured error message seen (turn.failed / error). The
    /// engine throws this at EOF so the user sees the real reason.
    private(set) var capturedError: String?

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
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = obj["type"] as? String
        else { return [] }

        switch type {
        case "item.started", "item.updated", "item.completed":
            guard let item = obj["item"] as? [String: Any] else { return [] }
            return parseItem(item)

        case "turn.completed":
            if let usage = obj["usage"] as? [String: Any] {
                Self.accumulateUsage(usage)
            }
            return []

        case "turn.failed":
            if let err = obj["error"] as? [String: Any],
               let msg = err["message"] as? String {
                capturedError = msg
            }
            return []

        case "error":
            if let msg = obj["message"] as? String {
                capturedError = msg
            }
            return []

        default:
            // thread.started / turn.started / item types we don't
            // render (command_execution, mcp_tool_call, …) collapse
            // to nothing.
            return []
        }
    }

    /// Extract a delta from an item snapshot. Defensive about field
    /// names across CLI versions: the discriminator may be `type`,
    /// `item_type`, or nested under `details.type`; the body may be
    /// `text`, nested `details.text`, or a `content` array of parts.
    private func parseItem(_ item: [String: Any]) -> [AIStreamEvent] {
        let id = (item["id"] as? String) ?? "default"
        let itemType = (item["item_type"] as? String)
            ?? (item["type"] as? String)
            ?? ((item["details"] as? [String: Any])?["type"] as? String)
            ?? ""
        let text = Self.extractText(item)
        guard !text.isEmpty else { return [] }

        guard let delta = diff(id: id, against: text) else { return [] }

        switch itemType {
        case "agent_message", "message", "assistant_message":
            return [.text(delta)]
        case "reasoning", "agent_reasoning", "thinking":
            return [.thinking(delta)]
        default:
            // Unknown renderable item with text — surface as visible
            // text rather than dropping it, so nothing silently
            // disappears if the schema adds a new message-like type.
            return [.text(delta)]
        }
    }

    private static func extractText(_ item: [String: Any]) -> String {
        if let t = item["text"] as? String { return t }
        if let details = item["details"] as? [String: Any],
           let t = details["text"] as? String { return t }
        if let msg = item["message"] as? String { return msg }
        // content: [{type, text}] array form.
        if let content = item["content"] as? [[String: Any]] {
            return content.compactMap { $0["text"] as? String }.joined()
        }
        return ""
    }

    /// Per-item suffix diff. Same idea as the Claude parser's `diff`
    /// but keyed by item id so concurrent reasoning + message streams
    /// don't clobber each other's accumulator.
    private func diff(id: String, against new: String) -> String? {
        let prev = yieldedByItem[id] ?? ""
        if new == prev { return nil }
        if new.hasPrefix(prev) {
            let added = String(new.dropFirst(prev.count))
            yieldedByItem[id] = new
            return added.isEmpty ? nil : added
        }
        // Wholesale replacement — rare; emit the full new text.
        yieldedByItem[id] = new
        return new
    }

    /// Roll Codex token usage into rolling counters, mirroring the
    /// Claude engine's `ai.claude.tokens.*` keys. The Settings page's
    /// "About"/usage surfaces can read these later; capturing now keeps
    /// the data flowing even if the UI lands afterwards.
    static func accumulateUsage(_ usage: [String: Any]) {
        let input  = (usage["input_tokens"]  as? Int) ?? (usage["prompt_tokens"]     as? Int) ?? 0
        let output = (usage["output_tokens"] as? Int) ?? (usage["completion_tokens"] as? Int) ?? 0
        let total = input + output
        guard total > 0 else { return }
        let d = UserDefaults.standard
        d.set(d.integer(forKey: "ai.codex.tokens.today") + total, forKey: "ai.codex.tokens.today")
        d.set(d.integer(forKey: "ai.codex.tokens.week")  + total, forKey: "ai.codex.tokens.week")
    }
}

enum CodexError: LocalizedError {
    case notInstalled
    case spawn(String)
    case runtime(String)
    case exit(code: Int32, stderr: String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "Codex CLI not found. Install with `npm i -g @openai/codex` (or `brew install codex`), then restart Helix Trading."
        case .spawn(let msg):
            return "Codex spawn failed: \(msg)"
        case .runtime(let msg):
            // Most common: an expired session. Nudge toward re-login.
            if msg.lowercased().contains("sign in") || msg.lowercased().contains("token") {
                return "\(msg)\n\nRun `codex login` in your terminal, then retry."
            }
            return msg
        case .exit(let code, let stderr):
            return stderr.isEmpty ? "Codex exited with code \(code)" : "Codex error: \(stderr)"
        }
    }
}
