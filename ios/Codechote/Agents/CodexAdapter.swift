import Foundation

/// OpenAI's Codex CLI. Its event format is newer and less settled than Claude Code's, so this adapter
/// is deliberately forgiving: anything it doesn't recognise is ignored rather than breaking the chat.
struct CodexAdapter: AgentAdapter {
    let kind = AgentKind.codex
    private let home = "${CODEX_HOME:-$HOME/.codex}"

    func locateCLI(on session: SSHSession) async -> String? {
        if session.os.isWindows {
            guard let result = try? await session.powershell("agent-locate", vars: ["Agent": .string("codex")]), result.succeeded else { return nil }
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        }
        let script = """
        for c in "${CODEX_BIN:-}" "$HOME/.local/bin/codex" /usr/local/bin/codex /opt/homebrew/bin/codex; do
          [ -n "$c" ] && [ -x "$c" ] && { echo "$c"; exit 0; }
        done
        ext=$(ls -d "$HOME"/.vscode-server/extensions/openai.chatgpt-*/bin/*/codex 2>/dev/null | { sort -V 2>/dev/null || sort; } | tail -1)
        [ -n "$ext" ] && [ -x "$ext" ] && { echo "$ext"; exit 0; }
        p=$(command -v codex 2>/dev/null); [ -n "$p" ] && { echo "$p"; exit 0; }
        p=$("${SHELL:-/bin/sh}" -lc 'command -v codex' 2>/dev/null | tail -1); [ -n "$p" ] && [ -x "$p" ] && { echo "$p"; exit 0; }
        exit 1
        """
        guard let result = try? await session.exec("sh -c \(shellQuote(script))"), result.succeeded else { return nil }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
    }

    func listSessions(on session: SSHSession, folder: String?) async -> [AgentSession] {
        let output: String
        if session.os.isWindows {
            guard let result = try? await session.powershell("agent-sessions", vars: ["Agent": .string("codex"), "Folder": .string("")]), result.succeeded else { return [] }
            output = result.stdout
        } else {
            let script = """
        for f in $(find \(home)/sessions -name 'rollout-*.jsonl' 2>/dev/null | xargs ls -t 2>/dev/null | head -50); do
          echo "@@FILE $f $(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f")"
          head -n 30 "$f" | cut -c1-3000
        done
        """
            guard let result = try? await session.exec("sh -c \(shellQuote(script))"), result.succeeded else { return [] }
            output = result.stdout
        }
        var sessions: [AgentSession] = []
        var id: String?, updated = Date.distantPast, title: String?, cwd: String?
        func flush() {
            guard let id else { return }
            if let folder, let cwd, cwd != folder { return }
            sessions.append(AgentSession(agent: .codex, id: id, title: title ?? "New conversation", updated: updated, folder: cwd))
        }
        for line in output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) {
            if line.hasPrefix("@@FILE ") {
                flush()
                let parts = line.dropFirst(7).split(separator: " ")
                let name = ((parts.first.map(String.init) ?? "") as NSString).deletingPathExtension
                id = String(name.suffix(36))
                updated = parts.last.flatMap { TimeInterval($0) }.map { Date(timeIntervalSince1970: $0) } ?? .distantPast
                title = nil; cwd = nil
                continue
            }
            guard let obj = AgentJSON.object(line) else { continue }
            let payload = obj["payload"] as? [String: Any] ?? obj
            if cwd == nil, let c = payload["cwd"] as? String { cwd = c }
            if title == nil, payload["type"] as? String == "user_message", let m = payload["message"] as? String { title = String(AgentJSON.userRequest(from: m).prefix(140)) }
            if title == nil, payload["type"] as? String == "message", payload["role"] as? String == "user",
               let parts = payload["content"] as? [[String: Any]], let t = parts.first?["text"] as? String, !t.hasPrefix("<") { title = String(AgentJSON.userRequest(from: t).prefix(140)) }
        }
        flush()
        return sessions.sorted { $0.updated > $1.updated }
    }

    private func locate(_ sessionID: String) -> String { "f=$(find \(home)/sessions -name '*\(sessionID)*.jsonl' 2>/dev/null | head -1)" }

    func transcriptSignature(on session: SSHSession, sessionID: String) async -> String? {
        await signature(of: locate(sessionID), on: session)
    }

    func deleteSession(on session: SSHSession, sessionID: String) async throws {
        try await delete(located: locate(sessionID), on: session)
    }

    func loadTranscript(on session: SSHSession, sessionID: String) async throws -> [ChatMessage] {
        let result: CommandResult
        if session.os.isWindows {
            result = try await session.powershell("agent-transcript", vars: ["Agent": .string("codex"), "SessionId": .string(sessionID)])
        } else {
            result = try await session.exec("sh -c \(shellQuote("f=$(find \(home)/sessions -name '*\(sessionID)*.jsonl' 2>/dev/null | head -1); [ -n \"$f\" ] && tail -c 6000000 \"$f\""))", maxBytes: 7_000_000)
        }
        var messages: [ChatMessage] = []
        for line in result.stdout.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let obj = AgentJSON.object(String(line)), let payload = obj["payload"] as? [String: Any] else { continue }
            switch payload["type"] as? String {
            case "user_message":
                if let text = payload["message"] as? String { messages.append(ChatMessage(id: "u\(messages.count)", role: .user, blocks: [.text(AgentJSON.userRequest(from: text))])) }
            case "agent_message":
                if let text = payload["message"] as? String { messages.append(ChatMessage(id: "a\(messages.count)", role: .assistant, blocks: [.text(text)])) }
            default: break
            }
        }
        return messages
    }

    func send(prompt: String, sessionID: String?, folder: String, mode: PermissionMode, model: String, allowedTools: [String], on session: SSHSession, cli: String) -> AsyncThrowingStream<AgentEvent, Error> {
        var args = ["exec"]
        if let sessionID { args += ["resume", sessionID] }
        args += ["--json", "--skip-git-repo-check"] + kind.modelArguments(model)
        switch mode {
        case .plan: args += ["--sandbox", "read-only"]
        case .acceptEdits: args += ["--sandbox", "workspace-write"]
        case .bypass: args += ["--dangerously-bypass-approvals-and-sandbox"]
        }
        args.append("-")   // read the prompt from stdin
        let launch = AgentLaunch(cli: cli, args: args, folder: folder, prompt: prompt)

        return AsyncThrowingStream { continuation in
            let task = Task {
                var counter = 0
                do {
                    for try await line in try await launch.lines(on: session) {
                        guard let obj = AgentJSON.object(line) else { continue }
                        let kind = obj["type"] as? String ?? ""
                        if kind == "thread.started", let id = obj["thread_id"] as? String { continuation.yield(.started(sessionID: id)) }
                        if kind == "item.completed", let item = obj["item"] as? [String: Any] {
                            counter += 1
                            let id = item["id"] as? String ?? "i\(counter)"
                            switch item["type"] as? String {
                            case "agent_message":
                                if let text = item["text"] as? String { continuation.yield(.message(ChatMessage(id: id, role: .assistant, blocks: [.text(text)]))) }
                            case "reasoning":
                                if let text = item["text"] as? String { continuation.yield(.message(ChatMessage(id: id, role: .assistant, blocks: [.thinking(text)]))) }
                            case "command_execution":
                                var call = ToolCall(id: id, name: "Bash", inputJSON: "", summary: item["command"] as? String ?? "")
                                call.result = item["aggregated_output"] as? String
                                call.isError = (item["exit_code"] as? Int ?? 0) != 0
                                continuation.yield(.message(ChatMessage(id: id, role: .assistant, blocks: [.tool(call)])))
                            case "file_change":
                                let changes = (item["changes"] as? [[String: Any]])?.compactMap { $0["path"] as? String }.joined(separator: ", ") ?? ""
                                continuation.yield(.message(ChatMessage(id: id, role: .assistant, blocks: [.tool(ToolCall(id: id, name: "Edit", inputJSON: "", summary: changes, result: nil))])))
                            default: break
                            }
                        }
                        if kind == "turn.completed" { continuation.yield(.finished(summary: nil)) }
                        if kind == "error" || kind == "turn.failed" {
                            let text = (obj["message"] as? String) ?? ((obj["error"] as? [String: Any])?["message"] as? String) ?? "Codex reported an error."
                            continuation.yield(.message(ChatMessage(id: "err\(counter)", role: .assistant, blocks: [.text(text)])))
                        }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
