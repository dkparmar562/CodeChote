import Foundation

/// Conversations with providers that don't keep a session file the app can read. The app keeps them itself, per
/// host, so they show up in the AI list and can be continued.
enum LocalChatStore {
    struct Turn: Codable, Equatable { var role: String; var text: String }
    struct Stored: Codable, Equatable {
        var id: String
        var agent: String
        var title: String
        var updated: Date
        var folder: String
        var turns: [Turn]
    }

    private static let lock = NSLock()

    private static func url(host: String) -> URL {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)) ?? FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("chats-\(host).json")
    }

    static func all(host: String) -> [Stored] {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: url(host: host)) else { return [] }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Stored].self, from: data)) ?? []
    }

    static func session(host: String, id: String) -> Stored? { all(host: host).first { $0.id == id } }

    static func remove(host: String, id: String) {
        var sessions = all(host: host)
        sessions.removeAll { $0.id == id }
        lock.lock(); defer { lock.unlock() }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(sessions) { try? data.write(to: url(host: host), options: .atomic) }
    }

    static func save(host: String, _ session: Stored) {
        var sessions = all(host: host)
        if let index = sessions.firstIndex(where: { $0.id == session.id }) { sessions[index] = session } else { sessions.append(session) }
        lock.lock(); defer { lock.unlock() }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(sessions) { try? data.write(to: url(host: host), options: .atomic) }
    }
}

/// Providers run once per message in their non-interactive mode, and the reply is shown as it prints.
/// They keep no session the app can resume, so earlier turns are sent along with each new message.
///
/// The command lines follow each CLI's documented headless mode, but none of them could be tried against a
/// real install here, so treat these as experimental.
struct CLIChatAdapter: AgentAdapter {
    let kind: AgentKind

    private var executable: String { kind.command ?? kind.rawValue }

    /// Flags before the prompt, which is always the last argument.
    func arguments(mode: PermissionMode, model: String = "") -> [String] {
        let chosen = kind.modelArguments(model)
        switch kind {
        case .cursor: return (mode == .bypass ? ["--force"] : []) + chosen + ["-p"]
        case .gemini: return (mode == .bypass ? ["--yolo"] : []) + chosen + ["-p"]
        case .copilot: return (mode == .bypass ? ["--allow-all-tools"] : []) + chosen + ["-p"]
        case .antigravity: return (mode == .bypass ? ["--dangerously-skip-permissions"] : []) + chosen + ["-p"]
        case .opencode, .kilo: return ["run"] + chosen
        default: return []
        }
    }

    func locateCLI(on session: SSHSession) async -> String? {
        if session.os.isWindows { return "windows-unsupported" }
        let name = executable
        let script = """
        for c in "${CODECHOTE_BIN_\(name.uppercased().replacingOccurrences(of: "-", with: "_")):-}" "$HOME/.local/bin/\(name)" "$HOME/.\(name)/bin/\(name)" "$HOME/.cursor/bin/\(name)" "$HOME/.opencode/bin/\(name)" "$HOME/.npm-global/bin/\(name)" "$HOME/.bun/bin/\(name)" /usr/local/bin/\(name) /opt/homebrew/bin/\(name); do
          [ -n "$c" ] && [ -x "$c" ] && { echo "$c"; exit 0; }
        done
        p=$(command -v \(name) 2>/dev/null); [ -n "$p" ] && { echo "$p"; exit 0; }
        p=$("${SHELL:-/bin/sh}" -lc 'command -v \(name)' 2>/dev/null | tail -1); [ -n "$p" ] && [ -x "$p" ] && { echo "$p"; exit 0; }
        exit 1
        """
        guard let result = try? await session.exec("sh -c \(shellQuote(script))"), result.succeeded else { return nil }
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    func listSessions(on session: SSHSession, folder: String?) async -> [AgentSession] {
        LocalChatStore.all(host: session.profile.id.uuidString)
            .filter { $0.agent == kind.rawValue && (folder == nil || $0.folder == folder) }
            .map { AgentSession(agent: kind, id: $0.id, title: $0.title, updated: $0.updated, folder: $0.folder) }
    }

    func deleteSession(on session: SSHSession, sessionID: String) async throws {
        LocalChatStore.remove(host: session.profile.id.uuidString, id: sessionID)
    }

    func loadTranscript(on session: SSHSession, sessionID: String) async throws -> [ChatMessage] {
        guard let stored = LocalChatStore.session(host: session.profile.id.uuidString, id: sessionID) else { return [] }
        return stored.turns.enumerated().map { index, turn in
            ChatMessage(id: "stored-\(index)", role: turn.role == "user" ? .user : .assistant, blocks: [.text(turn.text)])
        }
    }

    func send(prompt: String, sessionID: String?, folder: String, mode: PermissionMode, model: String, allowedTools: [String], on session: SSHSession, cli: String) -> AsyncThrowingStream<AgentEvent, Error> {
        let hostKey = session.profile.id.uuidString
        let id = sessionID ?? UUID().uuidString
        var stored = LocalChatStore.session(host: hostKey, id: id)
            ?? LocalChatStore.Stored(id: id, agent: kind.rawValue, title: String(prompt.prefix(60)), updated: Date(), folder: folder, turns: [])
        let fullPrompt = Self.composePrompt(history: stored.turns, prompt: prompt, readOnly: mode == .plan)
        let args = arguments(mode: mode, model: model)

        return AsyncThrowingStream { continuation in
            let task = Task {
                if sessionID == nil { continuation.yield(.started(sessionID: id)) }
                guard !session.os.isWindows else {
                    continuation.finish(throwing: SessionError(message: "\(kind.title) chat isn't available on Windows hosts yet. Open it in a terminal instead."))
                    return
                }
                let encoded = Data(fullPrompt.utf8).base64EncodedString()
                let quotedArgs = args.map(shellQuote).joined(separator: " ")
                let run = "\(shellQuote(cli)) \(quotedArgs) \"$p\""
                // Antigravity's print mode stays silent without a terminal, so it gets one from `script`
                // (util-linux on Linux, BSD on macOS take different arguments).
                let invoke = kind.needsTerminal
                    ? "export p; if script --version >/dev/null 2>&1; then script -qec \(shellQuote(run)) /dev/null; else script -q /dev/null sh -c \(shellQuote(run)); fi"
                    : run
                let command = "cd \(shellQuote(folder)) && p=$(printf %s \(shellQuote(encoded)) | \(SSHSession.base64Decode)) && \(invoke) 2>&1 </dev/null"
                var reply = ""
                do {
                    for try await raw in session.execLines(command) {
                        var line = Self.clean(raw)
                        // `script` echoes the end of input as ^D.
                        if kind.needsTerminal { line = line.replacingOccurrences(of: "^D", with: "").replacingOccurrences(of: "\u{08}", with: "") }
                        if line.isEmpty && reply.isEmpty { continue }
                        reply += line + "\n"
                        continuation.yield(.liveText(line + "\n"))
                    }
                    let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        continuation.yield(.message(ChatMessage(id: "cli-\(UUID().uuidString)", role: .assistant, blocks: [.text(text)])))
                        stored.turns += [.init(role: "user", text: prompt), .init(role: "assistant", text: text)]
                        stored.updated = Date()
                        LocalChatStore.save(host: hostKey, stored)
                    }
                    continuation.yield(.finished(summary: text.isEmpty ? "\(kind.title) printed nothing. Is it signed in? Open it in a terminal once to check." : nil))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Earlier turns first (capped), then the new message.
    nonisolated static func composePrompt(history: [LocalChatStore.Turn], prompt: String, readOnly: Bool) -> String {
        var parts: [String] = []
        if readOnly { parts.append("Plan only: do not modify any files or run commands that change anything.") }
        if !history.isEmpty {
            var lines: [String] = []
            var size = 0
            for turn in history.reversed() {
                let line = (turn.role == "user" ? "User: " : "Assistant: ") + turn.text
                size += line.count
                if size > 6000 { break }
                lines.insert(line, at: 0)
            }
            parts.append("Conversation so far:\n" + lines.joined(separator: "\n\n") + "\n\nNew message from the user:")
        }
        parts.append(prompt)
        return parts.joined(separator: "\n\n")
    }

    /// Removes colour codes and progress-spinner rewrites (carriage returns) from a line of terminal output.
    nonisolated static func clean(_ line: String) -> String {
        var text = line
        if let last = text.split(separator: "\r", omittingEmptySubsequences: true).last, text.contains("\r") { text = String(last) }
        return text.replacingOccurrences(of: #"\u001B\[[0-9;?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
    }
}

extension AgentKind {
    /// Installs an npm package globally, or into ~/.local when a global install isn't allowed (system Node.js),
    /// and says so plainly when Node.js isn't there at all.
    static func npmInstall(_ package: String) -> String {
        "if command -v npm >/dev/null 2>&1; then npm install -g \(package) || npm install -g --prefix \"$HOME/.local\" \(package); else echo 'Node.js (npm) is needed first. Install it from https://nodejs.org or with your package manager, then run this again.'; fi"
    }

    /// Its headless mode only prints when attached to a terminal.
    var needsTerminal: Bool { self == .antigravity }

    /// How to install the CLI, for the "isn't installed" notice. Check the provider's own docs if it has changed.
    var installHint: String {
        switch self {
        // The official installers: each puts the CLI in ~/.local/bin (or its own folder there), where the app looks.
        case .claude: "curl -fsSL https://claude.ai/install.sh | bash"
        case .cursor: "curl https://cursor.com/install -fsS | bash"
        case .opencode: "curl -fsSL https://opencode.ai/install | bash"
        case .antigravity: "curl -fsSL https://antigravity.google/cli/install.sh | bash"
        // npm packages.
        case .codex: Self.npmInstall("@openai/codex")
        case .kilo: Self.npmInstall("@kilocode/cli")
        case .gemini: Self.npmInstall("@google/gemini-cli")
        case .copilot: Self.npmInstall("@github/copilot")
        }
    }
}
