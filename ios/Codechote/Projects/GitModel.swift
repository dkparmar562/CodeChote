import Foundation
import Observation

struct GitChange: Identifiable, Hashable {
    enum Area { case staged, unstaged, untracked, conflict }
    let path: String
    let origPath: String?
    let status: Character      // M A D R C U ?
    let area: Area
    var id: String { "\(area)-\(path)" }
    var fileName: String { (path as NSString).lastPathComponent }
    var directory: String { (path as NSString).deletingLastPathComponent }

    var label: String {
        switch status {
        case "M": "Modified"
        case "A": "Added"
        case "D": "Deleted"
        case "R": "Renamed"
        case "C": "Copied"
        case "?": "Untracked"
        case "U": "Conflict"
        default: String(status)
        }
    }
}

struct GitCommit: Identifiable, Hashable {
    let hash: String
    let author: String
    let when: String
    let subject: String
    var id: String { hash }
}

/// The state of one repository on the host, read by running `git` over SSH.
@MainActor
@Observable
final class GitModel {
    private(set) var repo: String?
    private(set) var branch = ""
    private(set) var upstream: String?
    private(set) var ahead = 0
    private(set) var behind = 0
    private(set) var staged: [GitChange] = []
    private(set) var unstaged: [GitChange] = []
    private(set) var untracked: [GitChange] = []
    private(set) var conflicts: [GitChange] = []
    private(set) var commits: [GitCommit] = []
    private(set) var branches: [String] = []
    private(set) var isLoading = false
    var busy: String?
    var message: String?       // last error or result from a command
    private(set) var notARepo = false

    private let session: SSHSession
    private let folder: String

    init(session: SSHSession, folder: String) {
        self.session = session
        self.folder = folder
    }

    var hasChanges: Bool { !(staged.isEmpty && unstaged.isEmpty && untracked.isEmpty && conflicts.isEmpty) }

    // MARK: Running git

    /// Quotes for the host's shell: single quotes for sh, doubled single quotes for PowerShell.
    func q(_ text: String) -> String { session.os.isWindows ? PS.quote(text) : shellQuote(text) }

    /// Runs `git <args>` in the repository without ever waiting for a prompt. `okStatuses` lists exit codes
    /// that are not failures (`git diff --no-index` exits 1 when the files differ).
    @discardableResult
    func git(_ args: String, in directory: String? = nil, okStatuses: Set<Int> = [0]) async throws -> String {
        let dir = directory ?? repo ?? folder
        var result: CommandResult
        if session.os.isWindows {
            let script = "Set-Location -LiteralPath \(PS.quote(dir)); $env:GIT_TERMINAL_PROMPT='0'; $env:GIT_PAGER='cat'; $env:GIT_OPTIONAL_LOCKS='0'; $env:GIT_SSH_COMMAND='ssh -o BatchMode=yes'; & git -c core.quotepath=off \(args); exit $LASTEXITCODE"
            result = try await session.exec(PS.encodedCommand(script))
            result.stdout = result.stdout.replacingOccurrences(of: "\r\n", with: "\n")
            result.stderr = result.stderr.replacingOccurrences(of: "\r\n", with: "\n")
        } else {
            result = try await session.exec("cd \(q(dir)) && GIT_TERMINAL_PROMPT=0 GIT_PAGER=cat GIT_OPTIONAL_LOCKS=0 GIT_SSH_COMMAND='ssh -o BatchMode=yes' git -c core.quotepath=off \(args)")
        }
        guard okStatuses.contains(result.status) else {
            let text = (result.stderr.isEmpty ? result.stdout : result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            throw HostFileError(message: text.isEmpty ? "git failed (exit \(result.status))" : text)
        }
        return result.stdout + (result.stderr.isEmpty ? "" : "\n" + result.stderr)
    }

    // MARK: Refresh

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let top = try await git("rev-parse --show-toplevel", in: folder).trimmingCharacters(in: .whitespacesAndNewlines)
            repo = top
            notARepo = false
            try await readStatus()
            await readLog()
            await readBranches()
        } catch {
            let text = (error as? LocalizedError)?.errorDescription ?? ""
            if text.lowercased().contains("not a git repository") { notARepo = true; repo = nil } else { message = text }
        }
    }

    struct ParsedStatus {
        var branch = "", upstream: String?, ahead = 0, behind = 0
        var staged: [GitChange] = [], unstaged: [GitChange] = [], untracked: [GitChange] = [], conflicts: [GitChange] = []
    }

    private func readStatus() async throws {
        let parsed = Self.parseStatus(try await git("status --porcelain=v1 -b -uall"))
        branch = parsed.branch; upstream = parsed.upstream; ahead = parsed.ahead; behind = parsed.behind
        staged = parsed.staged; unstaged = parsed.unstaged; untracked = parsed.untracked; conflicts = parsed.conflicts
    }

    /// Parses `git status --porcelain=v1 -b`.
    nonisolated static func parseStatus(_ output: String) -> ParsedStatus {
        var result = ParsedStatus()
        for line in output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) {
            if line.hasPrefix("## ") {
                parseBranch(String(line.dropFirst(3)), into: &result)
                continue
            }
            guard line.count > 3 else { continue }
            let x = line[line.startIndex], y = line[line.index(after: line.startIndex)]
            var path = String(line.dropFirst(3))
            var orig: String?
            if let arrow = path.range(of: " -> ") { orig = String(path[..<arrow.lowerBound]); path = String(path[arrow.upperBound...]) }
            if x == "?" && y == "?" { result.untracked.append(GitChange(path: path, origPath: nil, status: "?", area: .untracked)); continue }
            if x == "U" || y == "U" || (x == "A" && y == "A") || (x == "D" && y == "D") { result.conflicts.append(GitChange(path: path, origPath: nil, status: "U", area: .conflict)); continue }
            if x != " " { result.staged.append(GitChange(path: path, origPath: orig, status: x, area: .staged)) }
            if y != " " { result.unstaged.append(GitChange(path: path, origPath: orig, status: y, area: .unstaged)) }
        }
        return result
    }

    /// `main...origin/main [ahead 2, behind 1]`, `main`, or `No commits yet on main`.
    private nonisolated static func parseBranch(_ text: String, into result: inout ParsedStatus) {
        var rest = text
        if let bracket = rest.range(of: " [") {
            let info = rest[bracket.upperBound...].dropLast()
            for part in info.split(separator: ",") {
                let p = part.trimmingCharacters(in: .whitespaces)
                if p.hasPrefix("ahead ") { result.ahead = Int(p.dropFirst(6)) ?? 0 }
                if p.hasPrefix("behind ") { result.behind = Int(p.dropFirst(7)) ?? 0 }
            }
            rest = String(rest[..<bracket.lowerBound])
        }
        if rest.hasPrefix("No commits yet on ") { result.branch = String(rest.dropFirst(18)); return }
        if let dots = rest.range(of: "...") {
            result.branch = String(rest[..<dots.lowerBound])
            result.upstream = String(rest[dots.upperBound...])
        } else {
            result.branch = rest
        }
    }

    private func readLog() async {
        let separator = "\u{1f}"
        guard let output = try? await git("log -n 40 --pretty=\(q("format:%h\(separator)%an\(separator)%ar\(separator)%s"))") else { commits = []; return }
        commits = output.split(separator: "\n").compactMap { line in
            let parts = line.components(separatedBy: separator)
            guard parts.count >= 4 else { return nil }
            return GitCommit(hash: parts[0], author: parts[1], when: parts[2], subject: parts[3...].joined(separator: separator))
        }
    }

    private func readBranches() async {
        guard let output = try? await git("branch --format='%(refname:short)'") else { return }
        branches = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    // MARK: Actions

    private func perform(_ label: String, refreshAfter: Bool = true, _ work: () async throws -> String?) async {
        busy = label
        message = nil
        do {
            if let result = try await work(), !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                message = result.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
        busy = nil
        if refreshAfter { await refresh() }
    }

    func stage(_ paths: [String]) async { await perform("Staging") { try await self.git("add -- " + paths.map(q).joined(separator: " ")); return nil } }
    func unstage(_ paths: [String]) async { await perform("Unstaging") { try await self.git("restore --staged -- " + paths.map(q).joined(separator: " ")); return nil } }
    func stageAll() async { await perform("Staging") { try await self.git("add -A"); return nil } }
    func unstageAll() async { await perform("Unstaging") { try await self.git("reset -q"); return nil } }

    func discard(_ change: GitChange) async {
        await perform("Discarding") {
            if change.area == .untracked { try await self.git("clean -f -- \(q(change.path))") }
            else { try await self.git("restore -- \(q(change.path))") }
            return nil
        }
    }

    func commit(message text: String, stageAllFirst: Bool) async -> Bool {
        var ok = false
        await perform("Committing") {
            if stageAllFirst { try await self.git("add -A") }
            let result = try await self.git("commit -m \(q(text))")
            ok = true
            return result
        }
        return ok
    }

    func fetch() async { await perform("Fetching") { try await self.git("fetch --prune") } }
    func pull() async { await perform("Pulling") { try await self.git("pull --ff-only") } }
    func push() async {
        await perform("Pushing") {
            if self.upstream == nil { return try await self.git("push -u origin HEAD") }
            return try await self.git("push")
        }
    }
    func switchBranch(_ name: String) async { await perform("Switching") { try await self.git("switch \(q(name))") } }
    func createBranch(_ name: String) async { await perform("Creating branch") { try await self.git("switch -c \(q(name))") } }
    func initRepository() async { await perform("Initialising") { try await self.git("init", in: self.folder) } }

    // MARK: Diffs

    func diff(for change: GitChange) async throws -> String {
        switch change.area {
        case .staged: return try await git("diff --cached --no-color -- \(q(change.path))")
        case .untracked:
            // A new file has no diff against the index; show it as all-added.
            return try await git("diff --no-color --no-index -- \(session.os.isWindows ? "NUL" : "/dev/null") \(q(change.path))", okStatuses: [0, 1])
        default: return try await git("diff --no-color -- \(q(change.path))")
        }
    }

    func show(commit: GitCommit) async throws -> String {
        try await git("show --no-color --stat --patch --format='%h  %an, %ar%n%n%B' \(commit.hash)")
    }
}
