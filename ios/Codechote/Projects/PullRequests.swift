import SwiftUI

/// Talks to GitHub through the `gh` CLI on the host, in the project's folder, so it uses the host's own sign-in.
struct GitHubCLI {
    let session: SSHSession
    let folder: String

    struct Failure: LocalizedError {
        enum Kind { case missing, signedOut, other }
        let kind: Kind
        let message: String
        var errorDescription: String? { message }
    }

    /// Runs `gh <args>` in a login shell (so Homebrew and other PATH entries apply), with optional input on stdin.
    func run(_ args: String, input: String? = nil) async throws -> String {
        guard !session.os.isWindows else { throw Failure(kind: .other, message: "Pull requests on Windows hosts aren't supported yet.") }
        let feed = input.map { "printf %s \(shellQuote(Data($0.utf8).base64EncodedString())) | \(SSHSession.base64Decode) | " } ?? ""
        let inner = "command -v gh >/dev/null 2>&1 || { echo '@@NOGH' >&2; exit 127; }; cd \(shellQuote(folder)) && GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 \(feed)gh \(args)"
        let result = try await session.exec("\"${SHELL:-/bin/sh}\" -lc \(shellQuote(inner))")
        guard result.succeeded else {
            let text = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.contains("@@NOGH") { throw Failure(kind: .missing, message: "The GitHub CLI (gh) isn't installed on this host.") }
            if text.contains("gh auth login") || text.lowercased().contains("not logged") { throw Failure(kind: .signedOut, message: "The GitHub CLI isn't signed in on this host.") }
            throw Failure(kind: .other, message: text.isEmpty ? "gh failed (exit \(result.status))" : text)
        }
        return result.stdout
    }

    func json(_ args: String) async throws -> Any {
        let text = try await run(args)
        guard let value = try? JSONSerialization.jsonObject(with: Data(text.utf8)) else { throw Failure(kind: .other, message: "Unexpected output from gh.") }
        return value
    }
}

struct PullRequest: Identifiable, Hashable {
    let number: Int
    let title: String
    let author: String
    let branch: String
    let updated: Date?
    let isDraft: Bool
    let review: String
    var id: Int { number }

    static func parse(_ object: [String: Any]) -> PullRequest? {
        guard let number = object["number"] as? Int, let title = object["title"] as? String else { return nil }
        return PullRequest(
            number: number, title: title,
            author: (object["author"] as? [String: Any])?["login"] as? String ?? "",
            branch: object["headRefName"] as? String ?? "",
            updated: (object["updatedAt"] as? String).flatMap(UsageReader.parseDate),
            isDraft: object["isDraft"] as? Bool ?? false,
            review: object["reviewDecision"] as? String ?? ""
        )
    }
}

/// The project's open pull requests.
struct PullRequestsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let hostID: UUID
    let folder: String

    @State private var pulls: [PullRequest] = []
    @State private var loading = true
    @State private var failure: GitHubCLI.Failure?
    @State private var setup: (title: String, command: String)?

    private var session: SSHSession? { model.connection(for: hostID)?.session }

    var body: some View {
        NavigationStack {
            List {
                if let failure {
                    Section {
                        Label(failure.message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        switch failure.kind {
                        case .missing:
                            Button("Install gh…") { setup = ("Install GitHub CLI", Self.installCommand) }
                        case .signedOut:
                            Button("Sign In to GitHub…") { setup = ("Sign In to GitHub", "gh auth login") }
                        case .other:
                            EmptyView()
                        }
                    }
                } else if loading && pulls.isEmpty {
                    HStack { ProgressView(); Text("Asking GitHub…").foregroundStyle(.secondary) }
                } else if pulls.isEmpty {
                    Text("No open pull requests.").foregroundStyle(.secondary)
                }
                ForEach(pulls) { pull in
                    NavigationLink { PullRequestDetail(hostID: hostID, folder: folder, number: pull.number) } label: { PullRow(pull: pull) }
                }
            }
            .navigationTitle("Pull Requests")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .refreshable { await load() }
            .task { await load() }
            .sheet(isPresented: Binding(get: { setup != nil }, set: { if !$0 { setup = nil } })) {
                if let setup, let session {
                    CommandSheet(title: setup.title, command: setup.command,
                                 note: "Runs in a terminal on the host. Follow its prompts; when it's done, come back and the list reloads.",
                                 session: session, folder: folder) { Task { await load() } }
                }
            }
        }
    }

    /// Homebrew where it exists (macOS, many Linux setups), otherwise the distribution's package manager.
    static let installCommand = "command -v brew >/dev/null && brew install gh || (command -v apt-get >/dev/null && sudo apt-get install -y gh) || (command -v dnf >/dev/null && sudo dnf install -y gh)"

    private func load() async {
        guard let session else { failure = .init(kind: .other, message: "Not connected."); loading = false; return }
        loading = true
        defer { loading = false }
        do {
            let list = try await GitHubCLI(session: session, folder: folder).json("pr list --limit 40 --json number,title,author,headRefName,updatedAt,isDraft,reviewDecision") as? [[String: Any]] ?? []
            pulls = list.compactMap(PullRequest.parse)
            failure = nil
        } catch let error as GitHubCLI.Failure {
            failure = error
        } catch {
            failure = .init(kind: .other, message: (error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }
}

private struct PullRow: View {
    let pull: PullRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(verbatim: "#\(pull.number)").font(.caption.monospacedDigit().weight(.semibold)).foregroundStyle(.secondary)
                if pull.isDraft { Text("Draft").font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2).background(Color.secondary.opacity(0.2), in: Capsule()) }
                if let badge = reviewBadge { Text(badge.0).font(.caption2.weight(.semibold)).foregroundStyle(badge.1) }
            }
            Text(pull.title).font(.subheadline.weight(.medium)).lineLimit(2)
            Text([pull.author, pull.branch, pull.updated.map { ChatRow.age($0) }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.vertical, 2)
    }

    private var reviewBadge: (String, Color)? {
        switch pull.review {
        case "APPROVED": ("Approved", .green)
        case "CHANGES_REQUESTED": ("Changes requested", .orange)
        case "REVIEW_REQUIRED": ("Review required", .secondary)
        default: nil
        }
    }
}

/// One pull request: description, checks, comments and reviews, the diff, and what you can do about it.
struct PullRequestDetail: View {
    @Environment(AppModel.self) private var model
    let hostID: UUID
    let folder: String
    let number: Int

    @State private var info: [String: Any] = [:]
    @State private var error: String?
    @State private var loaded = false
    @State private var diff: DiffRequest?
    @State private var writing: ReviewAction?
    @State private var text = ""
    @State private var working = false
    @State private var note: String?
    @State private var confirmCheckout = false

    enum ReviewAction: String, Identifiable { case comment, approve, requestChanges; var id: String { rawValue } }

    private var cli: GitHubCLI? { model.connection(for: hostID)?.session.map { GitHubCLI(session: $0, folder: folder) } }

    var body: some View {
        List {
            if let error { Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) } }
            if !loaded && error == nil { HStack { ProgressView(); Text("Loading…").foregroundStyle(.secondary) } }
            if loaded {
                Section {
                    Text(info["title"] as? String ?? "").font(.headline)
                    Text("\(author(info["author"])) wants to merge \(info["headRefName"] as? String ?? "") into \(info["baseRefName"] as? String ?? "")")
                        .font(.caption).foregroundStyle(.secondary)
                    if let checks = checksSummary { Label(checks.0, systemImage: checks.1).foregroundStyle(checks.2).font(.footnote) }
                }
                if let body = info["body"] as? String, !body.isEmpty {
                    Section("Description") { MarkdownView(text: body) }
                }
                Section {
                    Button { showDiff() } label: { Label("Changes · \((info["files"] as? [Any])?.count ?? 0) files", systemImage: "plus.forwardslash.minus") }
                    Button { askAgent() } label: { Label("Ask an Agent to Address the Feedback", systemImage: "wand.and.stars") }
                        .disabled(feedback.isEmpty)
                    Button { confirmCheckout = true } label: { Label("Check Out This Branch", systemImage: "arrow.triangle.branch") }
                }
                let items = feedback
                if !items.isEmpty {
                    Section("Reviews and comments") {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(item.author).font(.caption.weight(.semibold))
                                    if !item.state.isEmpty { Text(item.state.replacingOccurrences(of: "_", with: " ").capitalized).font(.caption2).foregroundStyle(.secondary) }
                                }
                                if !item.body.isEmpty { MarkdownView(text: item.body) }
                            }
                        }
                    }
                }
                Section("Review") {
                    Button("Comment…", systemImage: "text.bubble") { text = ""; writing = .comment }
                    Button("Approve…", systemImage: "checkmark.seal") { text = ""; writing = .approve }
                    Button("Request Changes…", systemImage: "exclamationmark.bubble") { text = ""; writing = .requestChanges }
                }
                if let note { Section { Text(note).font(.footnote).foregroundStyle(.secondary) } }
            }
        }
        .navigationTitle(Text(verbatim: "#\(number)"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { if working { ProgressView() } }
        .refreshable { await load() }
        .task { await load() }
        .sheet(item: $diff) { DiffSheet(request: $0) }
        .sheet(item: $writing) { action in reviewSheet(action) }
        .confirmationDialog("Check out #\(number)?", isPresented: $confirmCheckout, titleVisibility: .visible) {
            Button("Check Out") { Task { await perform("Checked out the branch.") { try await $0.run("pr checkout \(number)") } } }
        } message: { Text("The project folder switches to this pull request's branch. Commit or stash your own changes first.") }
    }

    private struct Feedback { let author: String; let state: String; let body: String }

    private var feedback: [Feedback] {
        let reviews = (info["reviews"] as? [[String: Any]] ?? []).map { Feedback(author: author($0["author"]), state: $0["state"] as? String ?? "", body: $0["body"] as? String ?? "") }
        let comments = (info["comments"] as? [[String: Any]] ?? []).map { Feedback(author: author($0["author"]), state: "", body: $0["body"] as? String ?? "") }
        return (reviews + comments).filter { !$0.body.isEmpty || $0.state == "CHANGES_REQUESTED" || $0.state == "APPROVED" }
    }

    private func author(_ value: Any?) -> String { (value as? [String: Any])?["login"] as? String ?? "someone" }

    private var checksSummary: (String, String, Color)? {
        guard let checks = info["statusCheckRollup"] as? [[String: Any]], !checks.isEmpty else { return nil }
        let states = checks.map { (($0["conclusion"] as? String) ?? ($0["state"] as? String) ?? ($0["status"] as? String) ?? "").uppercased() }
        let failed = states.filter { ["FAILURE", "ERROR", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED"].contains($0) }.count
        let pending = states.filter { ["PENDING", "IN_PROGRESS", "QUEUED", "EXPECTED", ""].contains($0) }.count
        if failed > 0 { return ("\(failed) of \(checks.count) checks failed", "xmark.circle.fill", .red) }
        if pending > 0 { return ("\(pending) of \(checks.count) checks running", "clock.fill", .orange) }
        return ("All \(checks.count) checks passed", "checkmark.circle.fill", .green)
    }

    private func load() async {
        guard let cli else { error = "Not connected."; return }
        do {
            info = try await cli.json("pr view \(number) --json title,body,author,headRefName,baseRefName,files,reviews,comments,statusCheckRollup,url") as? [String: Any] ?? [:]
            loaded = true
            error = nil
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    private func showDiff() {
        guard let cli else { return }
        let number = number
        diff = DiffRequest(title: "#\(number)") { try await cli.run("pr diff \(number) --color=never") }
    }

    /// A new chat in this project with the review feedback, using the agent you last started a chat with.
    private func askAgent() {
        let agent = AgentKind(rawValue: UserDefaults.standard.string(forKey: "newchat.agent") ?? "") ?? .claude
        let notes = feedback.map { "- \($0.author)\($0.state.isEmpty ? "" : " (\($0.state.lowercased().replacingOccurrences(of: "_", with: " ")))"): \($0.body)" }.joined(separator: "\n")
        let prompt = "Pull request #\(number) (\(info["title"] as? String ?? ""), branch `\(info["headRefName"] as? String ?? "")`) has this review feedback:\n\n\(notes)\n\nMake sure the branch is checked out, then address each point. Tell me what you changed."
        model.chats.startNew(agent, hostID: hostID, folder: folder, prompt: prompt)
    }

    @ViewBuilder private func reviewSheet(_ action: ReviewAction) -> some View {
        NavigationStack {
            Form {
                TextField(action == .approve ? "Comment (optional)" : "What to say", text: $text, axis: .vertical).lineLimit(4...12)
            }
            .navigationTitle(action == .comment ? "Comment" : action == .approve ? "Approve" : "Request Changes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { writing = nil } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        let body = text, number = number
                        writing = nil
                        Task {
                            await perform("Sent.") { cli in
                                switch action {
                                case .comment: return try await cli.run("pr comment \(number) --body-file -", input: body)
                                case .approve: return try await cli.run("pr review \(number) --approve --body-file -", input: body)
                                case .requestChanges: return try await cli.run("pr review \(number) --request-changes --body-file -", input: body)
                                }
                            }
                            await load()
                        }
                    }
                    .disabled(action != .approve && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func perform(_ done: String, _ work: (GitHubCLI) async throws -> String) async {
        guard let cli else { return }
        working = true
        defer { working = false }
        do { _ = try await work(cli); note = done } catch { note = (error as? LocalizedError)?.errorDescription ?? "\(error)" }
    }
}
