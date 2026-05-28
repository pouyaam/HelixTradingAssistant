import Foundation

/// Streams an analysis from the local `claude` CLI (Claude Code). Same
/// binary the user already runs from their terminal — no API key needed,
/// reuses their existing Claude session.
///
/// Approach: spawn `claude` with `--print` (non-interactive mode), write
/// the prompt on stdin, and relay stdout chunks onto the async stream.
/// Claude Code's `--print` mode emits plain text by default, which is
/// exactly what we want for the streaming Markdown analysis pane.
///
/// We deliberately avoid the HTTP Anthropic Messages API so the user
/// doesn't have to stash an API key in Keychain just to get analysis —
/// the CLI handles auth.
struct ClaudeEngine: AIEngine {
    let label = "Claude"

    var isAvailable: Bool {
        Self.locateBinary() != nil
    }

    var availability: EngineAvailability {
        if isAvailable { return .ready }
        return .notReady(hint: "Claude CLI not found. Install Claude Code, then restart Helix Trading.")
    }

    func run(system: String, user: String) -> AsyncThrowingStream<AIStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            guard let binary = Self.locateBinary() else {
                continuation.finish(throwing: ClaudeError.notInstalled)
                return
            }

            // Pull user-tunable model + effort from the same
            // @AppStorage keys the Settings page writes. Effort is
            // prepended to the system prompt as a soft hint — the
            // CLI doesn't expose a thinking-budget flag directly,
            // but the model takes a "use {high} effort" line
            // seriously when it's at the top of its system.
            let model = UserDefaults.standard.string(forKey: "ai.claude.model")
                ?? "claude-opus-4-7"
            let effort = UserDefaults.standard.string(forKey: "ai.claude.effort")
                ?? "medium"
            let effortLine = "Use **\(effort)** reasoning effort on this task.\n\n"

            // Claude CLI doesn't have a separate `--system` flag for the
            // system prompt. Concatenate the two with a delimiter; the
            // model still reads "you are a senior gold-market…" framing
            // up front and the task body below.
            let fullPrompt = """
            \(effortLine)\(system)

            ---

            \(user)
            """

            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            // Spawn cwd: a Helix-owned workspace folder that has a
            // pre-baked `.claude/settings.local.json` allowing all
            // tools. Claude reads that file when invoked, so it
            // skips the per-tool permission prompts that would
            // otherwise interrupt a non-interactive analysis run.
            let workspace = Self.prepareWorkspace()
            process.currentDirectoryURL = workspace
            // `--print` runs non-interactively, `stream-json` emits
            // one NDJSON event per delta so we can surface chunks
            // as Claude produces them. `--include-partial-messages`
            // turns on per-token content_block_delta events;
            // `--verbose` is required by Claude Code when using
            // stream-json output. `--model` selects the model
            // variant from settings. `--dangerously-skip-permissions`
            // is the belt to the settings.local.json's braces —
            // some Claude versions ignore the file when run from a
            // non-Git workspace, this flag covers that case.
            process.arguments = [
                "--print",
                "--output-format", "stream-json",
                "--include-partial-messages",
                "--verbose",
                "--dangerously-skip-permissions",
                "--model", model,
            ]

            // Inherit PATH so any post-launch hooks the user's
            // shell installs still resolve. Claude CLI needs HOME
            // for its session token; Foundation passes the parent's
            // env by default but we set it explicitly for clarity.
            var env = ProcessInfo.processInfo.environment
            env["NODE_NO_READLINE"] = "1"
            process.environment = env

            let stdinPipe = Pipe()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardInput = stdinPipe
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            // Cancellation: when the consumer stops iterating (Stop
            // button, sheet dismiss), kill the child so it doesn't keep
            // burning quota.
            continuation.onTermination = { _ in
                if process.isRunning { process.terminate() }
            }

            do {
                try process.run()
            } catch {
                continuation.finish(throwing: ClaudeError.spawn(error.localizedDescription))
                return
            }

            // Write the prompt to stdin and close — claude reads stdin
            // when --print is given without a positional prompt arg.
            if let data = fullPrompt.data(using: .utf8) {
                stdinPipe.fileHandleForWriting.write(data)
            }
            try? stdinPipe.fileHandleForWriting.close()

            // NDJSON parser state shared across readabilityHandler calls.
            // Each chunk may contain a partial line — we buffer until we
            // see '\n', then parse the line as JSON and extract any text
            // delta. `yieldedText` lets us also handle non-delta events
            // (e.g. a final `assistant` event with the full message) by
            // computing the diff against what we've already emitted.
            let parser = StreamJSONParser()

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    process.waitUntilExit()
                    if process.terminationStatus != 0 {
                        let err = String(
                            data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
                            encoding: .utf8
                        ) ?? ""
                        continuation.finish(throwing: ClaudeError.exit(
                            code: process.terminationStatus,
                            stderr: err.trimmingCharacters(in: .whitespacesAndNewlines)
                        ))
                    } else {
                        // Flush any trailing buffered line that didn't
                        // end in a newline (rare, but possible).
                        for event in parser.drain() {
                            continuation.yield(event)
                        }
                        continuation.finish()
                    }
                    return
                }
                for event in parser.consume(data) {
                    continuation.yield(event)
                }
            }
        }
    }

    // ── Workspace ──────────────────────────────────────────────────

    /// Resolve (creating if missing) the Helix-owned folder we
    /// spawn `claude` from. Lives under Application Support so the
    /// `.claude/settings.local.json` we write there is owned by
    /// the app, not by whatever directory the user happened to be
    /// in. The settings file pre-allows every tool so Claude's
    /// non-interactive `--print` runs never block on a permission
    /// prompt.
    ///
    /// Idempotent: the directory + settings file are written once
    /// on first call. Repeated invocations just return the URL.
    private static func prepareWorkspace() -> URL {
        let fm = FileManager.default
        // Anchor under the same Application Support base as the
        // database, so a "wipe Helix data" path takes the
        // workspace with it.
        let base = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        let workspace = base
            .appendingPathComponent("HelixTrading", isDirectory: true)
            .appendingPathComponent("claude-workspace", isDirectory: true)
        let claudeDir = workspace.appendingPathComponent(".claude", isDirectory: true)
        try? fm.createDirectory(at: claudeDir, withIntermediateDirectories: true)

        // Always (re)write the settings file so an upgrade that
        // bumps the allow-list lands without the user having to
        // delete the folder. Cheap — single file, write once per
        // run.
        let settings = claudeDir.appendingPathComponent("settings.local.json")
        let payload = """
        {
          "permissions": {
            "allow": ["*"],
            "deny": []
          },
          "trustedWorkspaces": true,
          "dontShowMessage": true
        }
        """
        try? payload.write(to: settings, atomically: true, encoding: .utf8)

        return workspace
    }

    // ── Binary location ────────────────────────────────────────────
    /// Find `claude` in the typical install locations. Mirrors
    /// `CodexEngine.locateBinary` — small static list keeps availability
    /// checks subprocess-free, which matters when the UI re-evaluates
    /// the property on every render. Honours `CLAUDE_BIN` env var for
    /// non-standard installs (e.g. nvm-managed Node versions).
    private static func locateBinary() -> String? {
        let candidates = [
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            NSHomeDirectory() + "/.claude/local/claude",
            NSHomeDirectory() + "/.local/bin/claude",
            NSHomeDirectory() + "/.npm-global/bin/claude",
            NSHomeDirectory() + "/.bun/bin/claude",
        ]
        var all = candidates
        if let custom = ProcessInfo.processInfo.environment["CLAUDE_BIN"], !custom.isEmpty {
            all.insert(custom, at: 0)
        }
        return all.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

/// NDJSON parser that pulls text + thinking deltas out of the
/// `claude --print --output-format stream-json` event stream.
/// Stateful because:
///   • stdout chunks don't align with newlines (one read can deliver
///     half an event followed by part of the next), so we buffer.
///   • Claude Code emits a few flavours of text-bearing event. We
///     watch for Anthropic SSE-style `content_block_delta` deltas
///     (the real per-token stream — both `text_delta` for the answer
///     and `thinking_delta` for the reasoning trace) and the
///     higher-level `assistant` event (used as a fallback if the
///     partial-messages flag isn't honoured by older CLIs). For the
///     latter we diff against the accumulated `yielded` text so we
///     never double-emit.
private final class StreamJSONParser {
    private var lineBuffer = Data()
    private var yielded = ""

    func consume(_ data: Data) -> [AIStreamEvent] {
        lineBuffer.append(data)
        var out: [AIStreamEvent] = []
        // Walk every complete newline-terminated line in the buffer.
        while let nl = lineBuffer.firstIndex(of: 0x0a) {
            let lineSlice = lineBuffer.prefix(nl)
            let line = Data(lineSlice)
            lineBuffer.removeSubrange(0...nl)
            out.append(contentsOf: parseLine(line))
        }
        return out
    }

    /// Flush any partial line left in the buffer at EOF. Most runs end
    /// with a clean newline; this is just defensive.
    func drain() -> [AIStreamEvent] {
        guard !lineBuffer.isEmpty else { return [] }
        let line = lineBuffer
        lineBuffer.removeAll()
        return parseLine(line)
    }

    /// Parse a single NDJSON line and return any deltas to yield.
    /// Unknown event types collapse to an empty array.
    private func parseLine(_ data: Data) -> [AIStreamEvent] {
        guard !data.isEmpty,
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = obj["type"] as? String
        else { return [] }

        switch type {
        case "stream_event":
            // Claude Code wraps the Anthropic SSE event under .event.
            // Also accumulate token usage when the embedded event
            // carries one (message_delta with usage payload).
            if let event = obj["event"] as? [String: Any] {
                Self.accumulateUsageFromEvent(event)
            }
            guard let event = obj["event"] as? [String: Any] else { return [] }
            return parseAnthropicEvent(event).map { [$0] } ?? []
        case "content_block_delta", "message_delta":
            Self.accumulateUsageFromEvent(obj)
            return parseAnthropicEvent(obj).map { [$0] } ?? []
        case "result":
            // Final summary event from Claude Code — has the
            // canonical token totals + total_cost_usd for the
            // whole turn. Roll into our usage counters; emit no
            // text deltas.
            if let usage = obj["usage"] as? [String: Any] {
                Self.accumulateUsage(usage)
            }
            return []
        case "assistant":
            // Cumulative event — full message content. Compute the
            // diff against what we've already streamed. Only the
            // visible text is diffed here; thinking blocks come
            // through the delta path above.
            guard let msg = obj["message"] as? [String: Any],
                  let content = msg["content"] as? [[String: Any]]
            else { return [] }
            let full = content.compactMap { block -> String? in
                guard (block["type"] as? String) == "text" else { return nil }
                return block["text"] as? String
            }.joined()
            return diff(against: full).map { [.text($0)] } ?? []
        default:
            return []
        }
    }

    /// Pull a delta out of an Anthropic SSE-style event. We surface
    /// two kinds: `text_delta` (final answer chunks) and
    /// `thinking_delta` (reasoning-trace chunks emitted by
    /// extended-thinking models). Everything else (tool use, signals,
    /// usage, …) is dropped — adding more event types later is
    /// straightforward.
    private func parseAnthropicEvent(_ event: [String: Any]) -> AIStreamEvent? {
        guard let type = event["type"] as? String,
              type == "content_block_delta",
              let delta = event["delta"] as? [String: Any],
              let deltaType = delta["type"] as? String
        else { return nil }

        switch deltaType {
        case "text_delta":
            guard let text = delta["text"] as? String, !text.isEmpty else { return nil }
            yielded += text
            return .text(text)
        case "thinking_delta":
            // Anthropic uses the `thinking` field for the reasoning
            // payload; some CLI versions key it as `text`. Accept
            // both for resilience.
            let payload = (delta["thinking"] as? String)
                       ?? (delta["text"] as? String)
                       ?? ""
            guard !payload.isEmpty else { return nil }
            return .thinking(payload)
        default:
            return nil
        }
    }

    /// Pull `usage.input_tokens` + `usage.output_tokens` out of a
    /// message-style event (Anthropic SSE message_delta carries
    /// these on the closing event). Skips when the event has no
    /// usage block — most chunked events don't.
    static func accumulateUsageFromEvent(_ event: [String: Any]) {
        // message_delta: usage at top level.
        if let usage = event["usage"] as? [String: Any] {
            accumulateUsage(usage)
        }
        // message_start: usage nested under "message".
        if let msg = event["message"] as? [String: Any],
           let usage = msg["usage"] as? [String: Any]
        {
            accumulateUsage(usage)
        }
    }

    /// Bump the today/week running token counters in UserDefaults
    /// (where the Settings page reads them via @AppStorage). The
    /// Settings view rolls the windows (day / ISO week) on its
    /// next render — no scheduler needed.
    static func accumulateUsage(_ usage: [String: Any]) {
        let input  = (usage["input_tokens"]  as? Int) ?? 0
        let output = (usage["output_tokens"] as? Int) ?? 0
        let total  = input + output
        guard total > 0 else { return }
        let d = UserDefaults.standard
        d.set((d.integer(forKey: "ai.claude.tokens.today") + total), forKey: "ai.claude.tokens.today")
        d.set((d.integer(forKey: "ai.claude.tokens.week")  + total), forKey: "ai.claude.tokens.week")
    }

    /// Yield only what's new vs `yielded`. Handles both the append case
    /// (prefix match) and a wholesale replacement (in which case we
    /// emit the whole new text).
    private func diff(against new: String) -> String? {
        if new == yielded { return nil }
        if new.hasPrefix(yielded) {
            let added = String(new.dropFirst(yielded.count))
            yielded = new
            return added.isEmpty ? nil : added
        }
        // Replacement — rare, only happens when an event resets the
        // text wholesale. Emit the full new text.
        yielded = new
        return new
    }
}

enum ClaudeError: LocalizedError {
    case notInstalled
    case spawn(String)
    case exit(code: Int32, stderr: String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "Claude CLI not found. Install Claude Code, then restart Helix Trading."
        case .spawn(let msg):
            return "Claude spawn failed: \(msg)"
        case .exit(let code, let stderr):
            return stderr.isEmpty ? "Claude exited with code \(code)" : "Claude error: \(stderr)"
        }
    }
}
