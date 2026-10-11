import Foundation

// How the app talks to each agent's CLI on a host.

protocol AgentAdapter {
    var kind: AgentKind { get }
    func locateCLI(on session: SSHSession) async -> String?
    func listSessions(on session: SSHSession, folder: String?) async -> [AgentSession]
    func loadTranscript(on session: SSHSession, sessionID: String) async throws -> [ChatMessage]
    /// `allowedTools` are permission rules you approved; only Claude Code uses them.
    func send(prompt: String, sessionID: String?, folder: String, mode: PermissionMode, model: String, allowedTools: [String], on session: SSHSession, cli: String) -> AsyncThrowingStream<AgentEvent, Error>
    /// Changes whenever the conversation's file changes (its size and time), so an open chat can tell when the
    /// conversation went on elsewhere (a terminal, VS Code) without reading the whole file. Nil if unknown.
    func transcriptSignature(on session: SSHSession, sessionID: String) async -> String?
    /// Deletes the conversation for good.
    func deleteSession(on session: SSHSession, sessionID: String) async throws
}

extension AgentAdapter {
    func transcriptSignature(on session: SSHSession, sessionID: String) async -> String? { nil }
    func deleteSession(on session: SSHSession, sessionID: String) async throws {
        throw SessionError(message: "\(kind.title) conversations can't be deleted from here.")
    }

    /// Size and modification time of the first file `locate` (a shell snippet setting `$f`) finds.
    func signature(of locate: String, on session: SSHSession) async -> String? {
        guard !session.os.isWindows else { return nil }
        let script = "\(locate); [ -n \"$f\" ] && { stat -f '%z %m' \"$f\" 2>/dev/null || stat -c '%s %Y' \"$f\"; }"
        guard let result = try? await session.exec("sh -c \(shellQuote(script))"), result.succeeded else { return nil }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
    }

    func delete(located locate: String, on session: SSHSession) async throws {
        guard !session.os.isWindows else { throw SessionError(message: "Deleting conversations on Windows hosts isn't supported yet.") }
        let script = "\(locate); [ -n \"$f\" ] || { echo 'Conversation not found' >&2; exit 1; }; rm -f -- \"$f\""
        let result = try await session.exec("sh -c \(shellQuote(script))")
        guard result.succeeded else { throw SessionError(message: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "Couldn't delete it") }
    }
}

func adapter(for kind: AgentKind) -> AgentAdapter {
    switch kind {
    case .claude: ClaudeAdapter()
    case .codex: CodexAdapter()
    case .cursor, .opencode, .kilo, .gemini, .copilot, .antigravity: CLIChatAdapter(kind: kind)
    }
}

// MARK: - Helpers

enum AgentJSON {
    /// The Codex extension wraps your prompt in IDE context; the part you actually typed follows this marker.
    static func userRequest(from text: String) -> String {
        if let range = text.range(of: "## My request for Codex:") {
            return String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    static func object(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8), let any = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return any as? [String: Any]
    }

    static func prettyJSON(_ value: Any?) -> String {
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// A one-line description of a tool call, for the collapsed card.
    static func summarize(tool name: String, input: [String: Any]) -> String {
        func str(_ key: String) -> String? { input[key] as? String }
        switch name {
        case "Bash": return str("command") ?? ""
        case "Read", "Write", "Edit", "MultiEdit", "NotebookEdit": return (str("file_path") ?? str("notebook_path")).map { ($0 as NSString).lastPathComponent } ?? ""
        case "Grep": return str("pattern") ?? ""
        case "Glob": return str("pattern") ?? ""
        case "WebFetch", "WebSearch": return str("url") ?? str("query") ?? ""
        case "Task": return str("description") ?? ""
        case "TodoWrite": return "Update to-dos"
        default:
            return input.values.compactMap { $0 as? String }.first ?? ""
        }
    }

    /// Tool results are a string or a list of `{type: text, text: …}` blocks.
    static func text(of content: Any?) -> String {
        if let s = content as? String { return s }
        if let blocks = content as? [[String: Any]] {
            return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        return ""
    }
}

/// How an agent CLI is started on the host: the prompt on stdin, output streamed back line by line.
struct AgentLaunch {
    let cli: String
    let args: [String]
    let folder: String
    let prompt: String

    /// With `streamingInput`, the prompt is the first line of a stream the job keeps open for more messages.
    var streamingInput = false

    func lines(on session: SSHSession) async throws -> AsyncThrowingStream<String, Error> {
        try await start(on: session).lines
    }

    /// Starts the agent. On Linux and macOS it runs as a job on the host, so it keeps going (and the app picks
    /// it up again) if the connection drops; the prompt goes in on stdin, with no quoting or length limits.
    func start(on session: SSHSession) async throws -> (job: HostJob?, lines: AsyncThrowingStream<String, Error>) {
        if session.os.isWindows {
            let b64 = Data(prompt.utf8).base64EncodedString()
            let command = try await session.windowsCommand(for: PS.loadScript("agent-run"), vars: [
                "Cwd": .string(folder), "Exe": .string(cli), "ArgList": .array(args), "PromptB64": .string(b64),
            ])
            return (nil, session.execLines(command))
        }
        let quotedArgs = args.map(shellQuote).joined(separator: " ")
        let job = try await HostJob.start("\(shellQuote(cli)) \(quotedArgs)", in: folder, input: prompt, streamingInput: streamingInput, on: session)
        return (job, job.lines())
    }
}
