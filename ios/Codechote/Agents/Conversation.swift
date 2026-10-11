import Foundation

// A conversation as the app keeps it, whichever agent it is with, and the events a running turn sends.

struct ToolCall: Equatable, Identifiable, Codable {
    let id: String
    var name: String
    var inputJSON: String
    var summary: String
    var result: String?
    var isError = false
}

enum ChatBlock: Equatable, Identifiable, Codable {
    case text(String)
    case thinking(String)
    case tool(ToolCall)

    var id: String {
        switch self {
        case .text(let t): "t-\(t.hashValue)"
        case .thinking(let t): "k-\(t.hashValue)"
        case .tool(let c): "c-\(c.id)"
        }
    }
}

struct ChatMessage: Identifiable, Equatable, Codable {
    enum Role: String, Codable { case user, assistant }
    let id: String
    var role: Role
    var blocks: [ChatBlock]

    /// The message's text, for copying.
    var plainText: String {
        blocks.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined(separator: "\n\n")
    }
}

/// One saved conversation on the host.
struct AgentSession: Identifiable, Hashable, Codable {
    let agent: AgentKind
    let id: String
    var title: String
    var updated: Date
    var folder: String?
    /// Which connected host it lives on, filled in when conversations from several hosts are listed together.
    var hostID: UUID?
    var hostName = ""

    /// Unique across hosts, for lists.
    var key: String { "\(hostID?.uuidString ?? "-")|\(agent.rawValue)|\(id)" }
}

/// A tool call the agent was not allowed to make. Approving it lets the agent retry with exactly that permission.
struct PermissionRequest: Identifiable, Equatable {
    let id: String
    let tool: String
    /// One line saying what it wanted to do, like the command it wanted to run.
    let summary: String
    /// The permission rule that would allow exactly this: the command for Bash, the tool's name otherwise.
    let rule: String

    init(id: String, tool: String, input: [String: Any]) {
        self.id = id
        self.tool = tool
        summary = AgentJSON.summarize(tool: tool, input: input)
        if tool == "Bash", let command = input["command"] as? String, !command.isEmpty { rule = "Bash(\(command))" } else { rule = tool }
    }

    /// Reads the `permission_denials` list at the end of a Claude Code run.
    static func parse(_ denials: Any?) -> [PermissionRequest] {
        guard let list = denials as? [[String: Any]] else { return [] }
        return list.compactMap { entry in
            guard let tool = entry["tool_name"] as? String else { return nil }
            return PermissionRequest(id: entry["tool_use_id"] as? String ?? UUID().uuidString, tool: tool, input: entry["tool_input"] as? [String: Any] ?? [:])
        }
    }
}

/// What the agent reports while a turn runs.
enum AgentEvent {
    case started(sessionID: String)
    case liveText(String)               // a streamed fragment of the reply
    case message(ChatMessage)           // a complete (or growing) assistant/user message
    case toolResult(toolID: String, text: String, isError: Bool)
    case finished(summary: String?)
    /// Tools the agent was blocked from using, waiting for your say-so.
    case permissionDenied([PermissionRequest])
    /// What the turn cost, when the agent reports it.
    case stats(TurnStats)
    /// The run on the host, for sending it more messages while it works.
    case job(HostJob)
}

/// Holds the run started inside a stream, so the stream's end can stop it.
final class JobBox: @unchecked Sendable { var job: HostJob? }

/// Totals for one turn, as Claude Code reports them at the end of a run.
struct TurnStats: Equatable, Codable {
    var inputTokens = 0
    var outputTokens = 0
    var costUSD: Double?
    var durationMS: Int?
    var turns: Int?

    static func parse(_ result: [String: Any]) -> TurnStats? {
        guard let usage = result["usage"] as? [String: Any] else { return nil }
        func int(_ key: String) -> Int { (usage[key] as? NSNumber)?.intValue ?? 0 }
        return TurnStats(
            inputTokens: int("input_tokens") + int("cache_read_input_tokens") + int("cache_creation_input_tokens"),
            outputTokens: int("output_tokens"),
            costUSD: (result["total_cost_usd"] as? NSNumber)?.doubleValue,
            durationMS: (result["duration_ms"] as? NSNumber)?.intValue,
            turns: (result["num_turns"] as? NSNumber)?.intValue
        )
    }

    /// "3 steps · 12.4K tokens · $0.06 · 41 s"
    var summary: String {
        var parts: [String] = []
        if let turns, turns > 1 { parts.append("\(turns) steps") }
        // Claude Code's cost figure is the whole session's running total (and means nothing on a subscription),
        // so only tokens and time are shown.
        if inputTokens + outputTokens > 0 { parts.append("\(UsageReader.compact(inputTokens + outputTokens)) tokens") }
        if let durationMS { parts.append(durationMS >= 60_000 ? "\(durationMS / 60_000) min \(durationMS % 60_000 / 1000) s" : "\(max(1, durationMS / 1000)) s") }
        return parts.joined(separator: " · ")
    }
}

/// How much the agent may do on its own while you are away from the keyboard.
enum PermissionMode: String, CaseIterable, Identifiable, Codable {
    case plan, acceptEdits, bypass
    var id: String { rawValue }
    var title: String {
        switch self {
        case .plan: "Plan only"
        case .acceptEdits: "Edit files"
        case .bypass: "Full access"
        }
    }
    var detail: String {
        switch self {
        case .plan: "Reads and plans; changes nothing."
        case .acceptEdits: "Edits files without asking. Other tools that need approval are declined."
        case .bypass: "Runs every tool without asking. Use with care."
        }
    }
    var symbol: String {
        switch self {
        case .plan: "doc.text.magnifyingglass"
        case .acceptEdits: "pencil"
        case .bypass: "bolt.fill"
        }
    }
}
