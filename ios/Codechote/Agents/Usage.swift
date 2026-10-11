import Foundation
import Observation

/// One limit window, like the bars in Claude's own usage screen.
struct UsageMeter: Identifiable, Equatable {
    var id: String { label }
    var label: String
    /// 0...1 of the limit used. Nil when only a raw amount is known (no limit to measure against).
    var fraction: Double?
    var detail: String?
    var resetsAt: Date?
}

struct UsageReport: Equatable {
    var agent: AgentKind
    var meters: [UsageMeter] = []
    var note: String?
    /// The account it is signed in with (an email or user name), so you know whose limits these are.
    var account: String?
    /// Which host it is for, when more than one is connected.
    var host = ""
    var key: String { "\(host)|\(agent.rawValue)" }
}

/// Reads how much of each agent's allowance has been used, and which account it is signed in with.
///
/// * Claude Code: the 5-hour and weekly limits, which the host asks Anthropic's usage service for with Claude
///   Code's own sign-in (the token never leaves the host). The service is not documented and may change.
/// * Codex: its rate limits, recorded in every session file, as of its last turn.
/// * GitHub Copilot: its monthly premium-request quota, from GitHub with the host's `gh` sign-in.
/// * The others don't publish usage; their card shows the account only.
enum UsageReader {
    static func fetch(_ agent: AgentKind, on host: SSHSession, planLookup: Bool = true) async -> UsageReport {
        guard !host.os.isWindows else {
            return UsageReport(agent: agent, note: "Usage isn't available for Windows hosts yet.")
        }
        var report: UsageReport
        switch agent {
        case .codex: report = await codex(on: host)
        case .claude: report = await claude(on: host)
        case .copilot: report = await copilot(on: host)
        default: report = UsageReport(agent: agent, note: "\(agent.title) doesn't publish its usage or limits.")
        }
        if report.account == nil { report.account = await account(agent, on: host) }
        return report
    }

    // MARK: Accounts

    /// Shell lines that print the signed-in account for each agent, read from its own files on the host.
    nonisolated static func accountScript(_ agent: AgentKind) -> String? {
        let email = #"grep -Eo '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' | head -1"#
        switch agent {
        case .claude:
            return #"for f in "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.claude.json" "$HOME/.claude.json"; do [ -f "$f" ] && grep -o '"emailAddress": *"[^"]*"' "$f" | head -1 | sed 's/.*: *"\(.*\)"/\1/' && break; done"#
        case .codex:
            // The email is inside the id_token (a JWT) in auth.json: decode its middle part.
            return #"f="${CODEX_HOME:-$HOME/.codex}/auth.json"; [ -f "$f" ] || exit 0; t=$(sed -n 's/.*"id_token": *"\([^"]*\)".*/\1/p' "$f" | head -1); [ -n "$t" ] || { "# + email + #" < "$f"; exit 0; }; printf '%s==' "$(printf %s "$t" | cut -d. -f2 | tr '_-' '/+')" | (base64 -d 2>/dev/null || base64 -D 2>/dev/null) | "# + email
        case .gemini, .antigravity:
            return #"for f in "$HOME/.gemini/google_accounts.json" "$HOME/.antigravity/google_accounts.json"; do [ -f "$f" ] && grep -o '"active": *"[^"]*"' "$f" | head -1 | sed 's/.*: *"\(.*\)"/\1/' && break; done"#
        case .cursor:
            return #""${SHELL:-/bin/sh}" -lc 'cursor-agent status 2>/dev/null' | "# + email
        case .copilot:
            return #""${SHELL:-/bin/sh}" -lc 'gh api user --jq .login 2>/dev/null' | head -1"#
        case .opencode, .kilo:
            return nil
        }
    }

    private static func account(_ agent: AgentKind, on host: SSHSession) async -> String? {
        guard let script = accountScript(agent), let result = try? await host.exec("sh -c \(shellQuote(script))") else { return nil }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
    }

    // MARK: Copilot

    private static func copilot(on host: SSHSession) async -> UsageReport {
        let command = #""${SHELL:-/bin/sh}" -lc 'gh api /copilot_internal/user 2>/dev/null'"#
        guard let result = try? await host.exec("sh -c \(shellQuote(command))"), result.succeeded,
              let report = parseCopilot(result.stdout) else {
            return UsageReport(agent: .copilot, note: "Sign in with the GitHub CLI (gh auth login) on the host to see Copilot's quota.")
        }
        return report
    }

    /// GitHub's Copilot entitlement: quota snapshots for premium requests and chat, and when they reset.
    nonisolated static func parseCopilot(_ json: String) -> UsageReport? {
        guard let root = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else { return nil }
        let snapshots = root["quota_snapshots"] as? [String: Any] ?? [:]
        let reset: Date? = (root["quota_reset_date"] as? String).flatMap { text in
            let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"; formatter.timeZone = TimeZone(identifier: "UTC")
            return formatter.date(from: text) ?? parseDate(text)
        }
        var meters: [UsageMeter] = []
        for (key, label) in [("premium_interactions", "Premium requests"), ("chat", "Chat")] {
            guard let quota = snapshots[key] as? [String: Any], quota["unlimited"] as? Bool != true,
                  let entitlement = (quota["entitlement"] as? NSNumber)?.doubleValue, entitlement > 0 else { continue }
            let remaining = (quota["remaining"] as? NSNumber)?.doubleValue ?? entitlement * ((quota["percent_remaining"] as? NSNumber)?.doubleValue ?? 100) / 100
            let used = max(0, entitlement - remaining)
            meters.append(UsageMeter(label: label, fraction: min(1, used / entitlement), detail: "\(Int(used)) of \(Int(entitlement))", resetsAt: reset))
        }
        let login = root["login"] as? String
        if meters.isEmpty { return UsageReport(agent: .copilot, note: root.isEmpty ? nil : "No limits on this Copilot plan.", account: login) }
        return UsageReport(agent: .copilot, meters: meters, account: login)
    }

    // MARK: Codex

    static let codexScript = """
    d="${CODEX_HOME:-$HOME/.codex}/sessions"
    [ -d "$d" ] || exit 0
    for f in $(find "$d" -name '*.jsonl' 2>/dev/null | xargs ls -t 2>/dev/null | head -5); do
      l=$(grep -h '"rate_limits"' "$f" 2>/dev/null | tail -1)
      [ -n "$l" ] && { echo "$l"; exit 0; }
    done
    """

    private static func codex(on host: SSHSession) async -> UsageReport {
        guard let result = try? await host.exec("sh -c \(shellQuote(codexScript))"), result.succeeded else {
            return UsageReport(agent: .codex, note: "Couldn't read Codex's session files.")
        }
        let line = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return UsageReport(agent: .codex, note: "No Codex usage recorded yet. Run a chat first.") }
        return parseCodexRateLimits(line) ?? UsageReport(agent: .codex, note: "Couldn't read Codex's usage format.")
    }

    nonisolated static func parseCodexRateLimits(_ line: String, now: Date = Date()) -> UsageReport? {
        guard let root = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { return nil }
        let payload = root["payload"] as? [String: Any] ?? root
        guard let limits = payload["rate_limits"] as? [String: Any] else { return nil }
        var recorded = now
        if let stamp = root["timestamp"] as? String { recorded = parseDate(stamp) ?? now }

        var meters: [UsageMeter] = []
        for key in ["primary", "secondary"] {
            guard let window = limits[key] as? [String: Any], let used = (window["used_percent"] as? NSNumber)?.doubleValue else { continue }
            let minutes = (window["window_minutes"] as? NSNumber)?.intValue
            var reset: Date?
            if let at = (window["resets_at"] as? NSNumber)?.doubleValue { reset = Date(timeIntervalSince1970: at) }
            else if let seconds = (window["resets_in_seconds"] as? NSNumber)?.doubleValue { reset = recorded.addingTimeInterval(seconds) }
            // A window that has already reset has nothing used in it yet.
            let expired = reset.map { $0 < now } ?? false
            meters.append(UsageMeter(label: windowLabel(minutes, fallback: key == "primary" ? "Session" : "Weekly"),
                                     fraction: expired ? 0 : min(1, max(0, used / 100)),
                                     detail: nil, resetsAt: expired ? nil : reset))
        }
        guard !meters.isEmpty else { return nil }
        return UsageReport(agent: .codex, meters: meters, note: "As of Codex's last turn.")
    }

    nonisolated static func windowLabel(_ minutes: Int?, fallback: String) -> String {
        guard let minutes else { return fallback }
        if minutes % 10080 == 0 { return minutes == 10080 ? "Weekly" : "\(minutes / 10080) weeks" }
        if minutes % 1440 == 0 { return "\(minutes / 1440) days" }
        if minutes % 60 == 0 { return "\(minutes / 60) hour" + (minutes == 60 ? "" : "s") }
        return "\(minutes) min"
    }

    // MARK: Claude

    /// `timestamp input output` for each assistant message from the last 7 days.
    static let claudeTokenScript = """
    d="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects"
    [ -d "$d" ] || exit 0
    find "$d" -name '*.jsonl' -mtime -7 2>/dev/null | head -300 | while read -r f; do
      grep -h '"output_tokens"' "$f" 2>/dev/null | tail -n 4000 | awk '{
        ts=""; i=0; o=0
        if (match($0, /"timestamp":"[^"]*"/)) ts=substr($0, RSTART+13, RLENGTH-14)
        if (match($0, /"input_tokens":[0-9]+/)) i=substr($0, RSTART+15, RLENGTH-15)
        if (match($0, /"output_tokens":[0-9]+/)) o=substr($0, RSTART+16, RLENGTH-16)
        if (ts != "") print ts, i, o }'
    done
    """

    /// The host reads Claude Code's own sign-in (a file on Linux; the login Keychain on macOS, readable while you
    /// are logged in at the Mac) and asks the usage service. `CLAUDE_USAGE_URL` overrides it (tests).
    static let claudePlanScript = """
    f="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json"
    if [ -f "$f" ]; then c=$(cat "$f"); else c=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null); fi
    [ -n "$c" ] || exit 3
    t=$(printf %s "$c" | sed -n 's/.*"accessToken": *"\\([^"]*\\)".*/\\1/p' | head -1)
    [ -n "$t" ] || exit 3
    curl -fsS -m 10 -H "Authorization: Bearer $t" -H "anthropic-beta: oauth-2025-04-20" "${CLAUDE_USAGE_URL:-https://api.anthropic.com/api/oauth/usage}"
    """

    /// The 5-hour and weekly limits, as Claude's own apps show them.
    private static func claude(on host: SSHSession) async -> UsageReport {
        guard let result = try? await host.exec("sh -c \(shellQuote(claudePlanScript))") else {
            return UsageReport(agent: .claude, note: "Couldn't ask the host.")
        }
        if result.succeeded, let plan = parseClaudePlan(result.stdout) { return plan }
        if result.status == 3 {
            return UsageReport(agent: .claude, note: "Claude Code isn't signed in on this host. (On a Mac, its sign-in is in the Keychain, which can only be read while you're logged in at the Mac.)")
        }
        return UsageReport(agent: .claude, note: "Anthropic's usage service didn't answer. Try again later.")
    }

    nonisolated static func parseClaudePlan(_ json: String, now: Date = Date()) -> UsageReport? {
        guard let root = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else { return nil }
        let windows: [(String, String)] = [("five_hour", "Session (5 hours)"), ("seven_day", "Weekly"), ("seven_day_opus", "Weekly, Opus"), ("seven_day_sonnet", "Weekly, Sonnet")]
        var meters: [UsageMeter] = []
        for (key, label) in windows {
            guard let window = root[key] as? [String: Any], let used = (window["utilization"] as? NSNumber)?.doubleValue else { continue }
            let reset = (window["resets_at"] as? String).flatMap(parseDate)
            meters.append(UsageMeter(label: label, fraction: min(1, max(0, used / 100)), detail: nil, resetsAt: reset.flatMap { $0 > now ? $0 : nil }))
        }
        return meters.isEmpty ? nil : UsageReport(agent: .claude, meters: meters)
    }

    nonisolated static func tokenWindows(from output: String, now: Date = Date()) -> (fiveHours: String, week: String) {
        var five = 0, week = 0
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ")
            guard parts.count == 3, let when = parseDate(String(parts[0])), let input = Int(parts[1]), let output = Int(parts[2]) else { continue }
            let age = now.timeIntervalSince(when)
            if age <= 7 * 86400 { week += input + output }
            if age <= 5 * 3600 { five += input + output }
        }
        return (compact(five) + " tokens", compact(week) + " tokens")
    }

    nonisolated static func compact(_ n: Int) -> String {
        n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1_000_000) : n >= 1000 ? String(format: "%.1fK", Double(n) / 1000) : "\(n)"
    }

    nonisolated static func parseDate(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter(); plain.formatOptions = [.withInternetDateTime]
        return fractional.date(from: text) ?? plain.date(from: text)
    }
}

@MainActor
@Observable
final class UsageStore {
    /// One for the app, so the settings screen and the chats screen agree.
    static let shared = UsageStore()

    var reports: [UsageReport] = []
    var isLoading = false
    /// Usage stays hidden until turned on in the AI settings.
    var showUsage = UserDefaults.standard.bool(forKey: "usage.show") {
        didSet { UserDefaults.standard.set(showUsage, forKey: "usage.show") }
    }
    /// Off until chosen: it makes the host call an Anthropic service with Claude Code's sign-in.
    var planLookup = UserDefaults.standard.bool(forKey: "usage.claudePlan") {
        didSet { UserDefaults.standard.set(planLookup, forKey: "usage.claudePlan") }
    }

    /// Hosts being asked right now, by name, for their section's spinner.
    private(set) var loadingHosts: Set<String> = []

    /// Reads usage from the given hosts. With `onlyThese`, other hosts' reports are kept (one host's refresh button);
    /// otherwise the list is replaced, so hosts no longer connected drop out.
    func refresh(hosts: [HostConnection], onlyThese: Bool = false) async {
        let names = Set(hosts.map(\.name))
        guard !names.isSubset(of: loadingHosts) || names.isEmpty else { return }
        isLoading = true
        loadingHosts.formUnion(names)
        defer { loadingHosts.subtract(names); isLoading = !loadingHosts.isEmpty }
        let plan = planLookup
        let targets = hosts.compactMap { host in host.session.map { (host.name, $0) } }
        var all: [UsageReport] = []
        await withTaskGroup(of: UsageReport?.self) { group in
            for (name, session) in targets {
                for agent in AgentKind.chatKinds {
                    group.addTask {
                        // Only agents installed on that host get a card.
                        guard await adapter(for: agent).locateCLI(on: session) != nil else { return nil }
                        var report = await UsageReader.fetch(agent, on: session, planLookup: plan)
                        report.host = name
                        return report
                    }
                }
            }
            for await report in group { if let report { all.append(report) } }
        }
        if onlyThese { all += reports.filter { !names.contains($0.host) } }
        // By host, then agents with limits first, then in the usual agent order.
        let order = Dictionary(uniqueKeysWithValues: AgentKind.allCases.enumerated().map { ($1, $0) })
        reports = all.sorted { ($0.host, $0.meters.isEmpty ? 1 : 0, order[$0.agent] ?? 0) < ($1.host, $1.meters.isEmpty ? 1 : 0, order[$1.agent] ?? 0) }
    }
}
