import Foundation

/// Claude Code, through its print mode with stream-json in and out.
struct ClaudeAdapter: AgentAdapter {
    let kind = AgentKind.claude

    /// Claude Code keeps its state under `$CLAUDE_CONFIG_DIR` or `~/.claude`.
    private let configDir = "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

    func locateCLI(on session: SSHSession) async -> String? {
        if session.os.isWindows {
            guard let result = try? await session.powershell("agent-locate", vars: ["Agent": .string("claude")]), result.succeeded else { return nil }
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        }
        // Non-interactive SSH has a bare PATH, so look in the usual homes as well as asking a login shell.
        let script = """
        for c in "${CLAUDE_BIN:-}" "$HOME/.claude/local/claude" "$HOME/.local/bin/claude" /usr/local/bin/claude /opt/homebrew/bin/claude; do
          [ -n "$c" ] && [ -x "$c" ] && { echo "$c"; exit 0; }
        done
        ext=$(ls -d "$HOME"/.vscode-server/extensions/anthropic.claude-code-*/resources/native-binary/claude 2>/dev/null | { sort -V 2>/dev/null || sort; } | tail -1)
        [ -n "$ext" ] && [ -x "$ext" ] && { echo "$ext"; exit 0; }
        p=$(command -v claude 2>/dev/null); [ -n "$p" ] && { echo "$p"; exit 0; }
        p=$("${SHELL:-/bin/sh}" -lc 'command -v claude' 2>/dev/null | tail -1); [ -n "$p" ] && [ -x "$p" ] && { echo "$p"; exit 0; }
        exit 1
        """
        guard let result = try? await session.exec("sh -c \(shellQuote(script))"), result.succeeded else { return nil }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
    }

    /// Claude Code names a project's folder after its path with every non-alphanumeric character turned
    /// into `-`: `/Users/me/proj` is `-Users-me-proj`, `C:/Users/me/proj` is `C--Users-me-proj`.
    static func encode(folder: String) -> String {
        String(folder.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
    }

    func listSessions(on session: SSHSession, folder: String?) async -> [AgentSession] {
        if session.os.isWindows {
            guard let result = try? await session.powershell("agent-sessions", vars: ["Agent": .string("claude"), "Folder": .string(folder ?? "")]), result.succeeded else { return [] }
            return Self.parseListing(result.stdout)
        }
        let dirs = folder.map { "\(configDir)/projects/\(Self.encode(folder: $0))" } ?? "\(configDir)/projects/*"
        let script = """
        for f in $(ls -t \(dirs)/*.jsonl 2>/dev/null | head -60); do
          echo "@@FILE $f $(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f")"
          head -n 40 "$f" | cut -c1-3000
        done
        """
        guard let result = try? await session.exec("sh -c \(shellQuote(script))"), result.succeeded else { return [] }
        return Self.parseListing(result.stdout)
    }

    static func parseListing(_ output: String) -> [AgentSession] {
        var sessions: [AgentSession] = []
        var path = "", updated = Date.distantPast
        var title: String?, summary: String?, cwd: String?
        func flush() {
            guard !path.isEmpty else { return }
            let id = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            sessions.append(AgentSession(agent: .claude, id: id, title: summary ?? title ?? "New conversation", updated: updated, folder: cwd))
        }
        for line in output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) {
            if line.hasPrefix("@@FILE ") {
                flush()
                let parts = line.dropFirst(7).split(separator: " ")
                path = parts.first.map(String.init) ?? ""
                updated = parts.last.flatMap { TimeInterval($0) }.map { Date(timeIntervalSince1970: $0) } ?? .distantPast
                title = nil; summary = nil; cwd = nil
                continue
            }
            guard let obj = AgentJSON.object(line) else { continue }
            if cwd == nil, let c = obj["cwd"] as? String { cwd = c }
            if obj["type"] as? String == "summary", summary == nil, let s = obj["summary"] as? String { summary = s }
            if title == nil, obj["type"] as? String == "user", obj["isMeta"] as? Bool != true,
               let message = obj["message"] as? [String: Any] {
                title = firstUserText(message["content"])
            }
        }
        flush()
        return sessions.sorted { $0.updated > $1.updated }
    }

    /// The first thing the user typed, skipping the system wrappers Claude Code logs as "user" turns.
    private static func firstUserText(_ content: Any?) -> String? {
        var text: String?
        if let s = content as? String { text = s }
        else if let blocks = content as? [[String: Any]] { text = blocks.first { $0["type"] as? String == "text" }?["text"] as? String }
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              !text.hasPrefix("<"), !text.hasPrefix("Caveat:") else { return nil }
        return String(text.prefix(140))
    }

    private func locate(_ sessionID: String) -> String { "f=$(ls \(configDir)/projects/*/\(sessionID).jsonl 2>/dev/null | head -1)" }

    func transcriptSignature(on session: SSHSession, sessionID: String) async -> String? {
        await signature(of: locate(sessionID), on: session)
    }

    func deleteSession(on session: SSHSession, sessionID: String) async throws {
        try await delete(located: locate(sessionID), on: session)
    }

    func loadTranscript(on session: SSHSession, sessionID: String) async throws -> [ChatMessage] {
        let result: CommandResult
        if session.os.isWindows {
            result = try await session.powershell("agent-transcript", vars: ["Agent": .string("claude"), "SessionId": .string(sessionID)])
        } else {
            // The newest part of a long conversation matters most: read the end (a cut first line is skipped).
            result = try await session.exec("sh -c \(shellQuote("f=$(ls \(configDir)/projects/*/\(sessionID).jsonl 2>/dev/null | head -1); [ -n \"$f\" ] && tail -c 6000000 \"$f\""))", maxBytes: 7_000_000)
        }
        guard result.succeeded else { return [] }
        var assembler = MessageAssembler()
        for line in result.stdout.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let obj = AgentJSON.object(String(line)) else { continue }
            if obj["isSidechain"] as? Bool == true || obj["isMeta"] as? Bool == true { continue }
            assembler.consume(obj)
        }
        return assembler.messages
    }

    func send(prompt: String, sessionID: String?, folder: String, mode: PermissionMode, model: String, allowedTools: [String], on session: SSHSession, cli: String) -> AsyncThrowingStream<AgentEvent, Error> {
        var args = ["-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages"]
        switch mode {
        case .plan: args += ["--permission-mode", "plan"]
        case .acceptEdits: args += ["--permission-mode", "acceptEdits"]
        case .bypass: args += ["--dangerously-skip-permissions"]
        }
        if let sessionID { args += ["--resume", sessionID] }
        args += kind.modelArguments(model)
        // Approved rules go last: the flag takes every argument after it as a rule (the prompt goes in on stdin).
        if !allowedTools.isEmpty { args += ["--allowedTools"] + allowedTools }
        // On Linux and macOS the input stays open (stream-json), so messages sent while it works reach it at once.
        let streaming = !session.os.isWindows
        if streaming { args.insert(contentsOf: ["--input-format", "stream-json"], at: 1) }
        let launch = AgentLaunch(cli: cli, args: args, folder: folder, prompt: streaming ? Self.inputLine(prompt) : prompt, streamingInput: streaming)
        let jobBox = JobBox()

        return AsyncThrowingStream { continuation in
            let task = Task {
                var assembler = MessageAssembler()
                var sawAnything = false
                var results = 0
                do {
                    let started = try await launch.start(on: session)
                    jobBox.job = started.job
                    if let job = started.job { continuation.yield(.job(job)) }
                    for try await line in started.lines {
                        guard let obj = AgentJSON.object(line) else {
                            // Not JSON: an error or notice from the CLI itself.
                            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !text.isEmpty { continuation.yield(.liveText("")); sawAnything = true; continuation.yield(.message(ChatMessage(id: "note-\(UUID().uuidString)", role: .assistant, blocks: [.text(text)]))) }
                            continue
                        }
                        sawAnything = true
                        switch obj["type"] as? String {
                        case "system":
                            if obj["subtype"] as? String == "init", let id = obj["session_id"] as? String { continuation.yield(.started(sessionID: id)) }
                        case "stream_event":
                            if let event = obj["event"] as? [String: Any], event["type"] as? String == "content_block_delta",
                               let delta = event["delta"] as? [String: Any], let t = delta["text"] as? String { continuation.yield(.liveText(t)) }
                        case "assistant", "user":
                            let before = assembler.messages
                            assembler.consume(obj)
                            for message in assembler.messages where !before.contains(message) { continuation.yield(.message(message)) }
                            if obj["type"] as? String == "user", let blocks = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]] {
                                for block in blocks where block["type"] as? String == "tool_result" {
                                    continuation.yield(.toolResult(toolID: block["tool_use_id"] as? String ?? "", text: AgentJSON.text(of: block["content"]), isError: block["is_error"] as? Bool ?? false))
                                }
                            }
                        case "result":
                            var summary: String?
                            if obj["is_error"] as? Bool == true { summary = obj["result"] as? String }
                            let denied = PermissionRequest.parse(obj["permission_denials"])
                            if !denied.isEmpty { continuation.yield(.permissionDenied(denied)) }
                            if let stats = TurnStats.parse(obj) { continuation.yield(.stats(stats)) }
                            // Every message has had its answer: end the input so Claude Code finishes.
                            results += 1
                            if let job = jobBox.job, results >= job.inputs { job.closeInput() }
                            continuation.yield(.finished(summary: summary))
                        default: break
                        }
                    }
                    if !sawAnything { continuation.yield(.message(ChatMessage(id: "empty", role: .assistant, blocks: [.text("No output from Claude Code. Check that it is installed and signed in on the host.")]))) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { reason in
                task.cancel()
                // Stopped from the app: end the run on the host too.
                if case .cancelled = reason { jobBox.job?.stop() }
            }
        }
    }

    /// A message in Claude Code's stream-json input format.
    static func inputLine(_ text: String) -> String {
        let message: [String: Any] = ["type": "user", "message": ["role": "user", "content": [["type": "text", "text": text]]]]
        let data = (try? JSONSerialization.data(withJSONObject: message)) ?? Data()
        return String(decoding: data, as: UTF8.self) + "\n"
    }
}

/// Builds messages from Claude's event lines: one message arrives as several lines (one per content block),
/// and tool results arrive later as separate "user" lines that belong to an earlier tool call.
struct MessageAssembler {
    private(set) var messages: [ChatMessage] = []

    mutating func consume(_ obj: [String: Any]) {
        guard let type = obj["type"] as? String, type == "assistant" || type == "user",
              let message = obj["message"] as? [String: Any] else { return }
        let role: ChatMessage.Role = type == "user" ? .user : .assistant
        let id = (message["id"] as? String) ?? (obj["uuid"] as? String) ?? UUID().uuidString

        var blocks: [ChatBlock] = []
        if let text = message["content"] as? String {
            if role == .user, text.hasPrefix("<") { return }   // wrapper turns such as command output
            blocks = [.text(text)]
        } else if let items = message["content"] as? [[String: Any]] {
            for item in items {
                switch item["type"] as? String {
                case "text":
                    if let t = item["text"] as? String, !t.isEmpty { blocks.append(.text(t)) }
                case "thinking":
                    if let t = item["thinking"] as? String, !t.isEmpty { blocks.append(.thinking(t)) }
                case "tool_use":
                    let name = item["name"] as? String ?? "Tool"
                    let input = item["input"] as? [String: Any] ?? [:]
                    blocks.append(.tool(ToolCall(id: item["id"] as? String ?? UUID().uuidString, name: name, inputJSON: AgentJSON.prettyJSON(input), summary: AgentJSON.summarize(tool: name, input: input))))
                case "tool_result":
                    attach(toolID: item["tool_use_id"] as? String ?? "", text: AgentJSON.text(of: item["content"]), isError: item["is_error"] as? Bool ?? false)
                default: break
                }
            }
        }
        guard !blocks.isEmpty else { return }

        if let index = messages.firstIndex(where: { $0.id == id && $0.role == role }) {
            for block in blocks where !messages[index].blocks.contains(block) { messages[index].blocks.append(block) }
        } else {
            messages.append(ChatMessage(id: id, role: role, blocks: blocks))
        }
    }

    mutating func attach(toolID: String, text: String, isError: Bool) {
        for m in messages.indices {
            for b in messages[m].blocks.indices {
                if case .tool(var call) = messages[m].blocks[b], call.id == toolID {
                    call.result = text; call.isError = isError
                    messages[m].blocks[b] = .tool(call)
                    return
                }
            }
        }
    }
}
