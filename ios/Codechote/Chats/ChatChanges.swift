import SwiftUI

extension ChatModel {
    /// Files the agent wrote or edited in this conversation, as absolute paths, newest first.
    var touchedFiles: [String] {
        var seen = Set<String>(), result: [String] = []
        for message in messages.reversed() where message.role == .assistant {
            for block in message.blocks {
                guard case .tool(let call) = block, ["Edit", "MultiEdit", "Write", "NotebookEdit"].contains(call.name), !call.isError,
                      let path = ToolText.path(call) else { continue }
                let absolute = path.hasPrefix("/") || path.dropFirst().first == ":" ? path : folder + "/" + path
                if seen.insert(absolute).inserted { result.append(absolute) }
            }
        }
        return result
    }
}

/// One repository a conversation's changes are in, with the chat's files as paths inside it.
struct ChangedRepo: Identifiable {
    let path: String
    let git: GitModel
    var touched: Set<String>
    var id: String { path }
}

/// Finds the repositories involved: the project's own, ones nested in it (a few levels down), and the ones
/// holding each file the chat touched, which may be outside the project.
enum RepoDiscovery {
    struct Found: Equatable {
        var repos: [String] = []
        /// Repository → the chat's files in it, relative to its root.
        var files: [String: Set<String>] = [:]
    }

    /// The host script: `R <root>` per repository and `F <root> <relative path>` per touched file.
    static let script = #"""
    cd "$1" 2>/dev/null || exit 0
    top=$(git rev-parse --show-toplevel 2>/dev/null) && printf 'R\t%s\n' "$top"
    find . -maxdepth 3 \( -name node_modules -o -name .build -o -name Pods \) -prune -o -name .git -print -prune 2>/dev/null | while IFS= read -r g; do
      top=$(git -C "$(dirname "$g")" rev-parse --show-toplevel 2>/dev/null) && printf 'R\t%s\n' "$top"
    done
    shift
    for f in "$@"; do
      d=$(dirname "$f")
      while [ ! -d "$d" ] && [ "$d" != "/" ] && [ "$d" != "." ]; do d=$(dirname "$d"); done
      top=$(git -C "$d" rev-parse --show-toplevel 2>/dev/null) || continue
      prefix=$(git -C "$d" rev-parse --show-prefix 2>/dev/null)
      printf 'F\t%s\t%s%s\n' "$top" "$prefix" "${f#"$d"/}"
    done
    """#

    nonisolated static func parse(_ output: String) -> Found {
        var found = Found()
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 2, !parts[1].isEmpty else { continue }
            if !found.repos.contains(parts[1]) { found.repos.append(parts[1]) }
            if parts[0] == "F", parts.count >= 3 { found.files[parts[1], default: []].insert(parts[2]) }
        }
        return found
    }

    static func find(on session: SSHSession, folder: String, touched: [String]) async -> Found {
        let files = touched.prefix(300).map(shellQuote).joined(separator: " ")
        guard let result = try? await session.exec("sh -c \(shellQuote(script)) sh \(shellQuote(folder)) \(files)") else { return Found() }
        return parse(result.stdout)
    }
}

/// What a conversation changed: the files it touched with their diffs (from git), to keep, revert or commit,
/// one section per repository.
struct ChatChangesSheet: View {
    @Environment(\.dismiss) private var dismiss
    let session: SSHSession
    let folder: String
    let touched: [String]

    @State private var repos: [ChangedRepo]?
    @State private var diff: DiffRequest?
    @State private var reverting: (git: GitModel, change: GitChange)?

    var body: some View {
        NavigationStack {
            List {
                if let repos {
                    if repos.isEmpty {
                        Section {
                            Text("This project isn't a git repository, so changes can't be compared. These are the files the agent wrote:").font(.footnote).foregroundStyle(.secondary)
                            ForEach(touched, id: \.self) { Text(($0 as NSString).lastPathComponent).font(.body.monospaced()) }
                        }
                    } else {
                        if touched.isEmpty {
                            Section { Text("This chat hasn't changed any files.").foregroundStyle(.secondary) }
                        }
                        ForEach(shown(repos)) { repo in
                            RepoChangesSection(repo: repo, title: repos.count > 1 ? name(of: repo.path) : nil,
                                               onDiff: { diff = $0 }, onRevert: { reverting = (repo.git, $0) })
                        }
                    }
                } else {
                    HStack { ProgressView(); Text("Reading changes…").foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Changes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { if repos?.contains(where: { $0.git.busy != nil }) == true { ProgressView() } }
            }
            .refreshable { await refresh() }
            .task { await load() }
            .sheet(item: $diff) { DiffSheet(request: $0) }
            .confirmationDialog("Revert this file?", isPresented: Binding(get: { reverting != nil }, set: { if !$0 { reverting = nil } }), titleVisibility: .visible) {
                Button(reverting?.change.area == .untracked ? "Delete File" : "Revert Changes", role: .destructive) {
                    if let target = reverting { Task { await target.git.discard(target.change) } }
                    reverting = nil
                }
            } message: { Text(reverting?.change.area == .untracked ? "It's a new file, so reverting deletes it." : "Its uncommitted changes are thrown away.") }
        }
    }

    /// Repositories with this chat's files first; ones with nothing to show are left out unless it's the only one.
    private func shown(_ repos: [ChangedRepo]) -> [ChangedRepo] {
        let ordered = repos.filter { !$0.touched.isEmpty } + repos.filter { $0.touched.isEmpty }
        let visible = ordered.filter { !$0.touched.isEmpty || $0.git.hasChanges || $0.git.isLoading }
        return visible.isEmpty ? Array(ordered.prefix(1)) : visible
    }

    /// A repository's name, as a path inside the project when it's there.
    private func name(of path: String) -> String {
        if path == folder { return (path as NSString).lastPathComponent }
        if path.hasPrefix(folder + "/") { return String(path.dropFirst(folder.count + 1)) }
        return (path as NSString).abbreviatingWithTildeInPath
    }

    private func load() async {
        guard repos == nil else { return }
        if session.os.isWindows {
            // Only the project's own repository; paths are matched against its root.
            let git = GitModel(session: session, folder: folder)
            await git.refresh()
            guard let root = git.repo else { repos = []; return }
            let files = Set(touched.compactMap { file -> String? in
                let normalized = file.replacingOccurrences(of: "\\", with: "/")
                let base = root.replacingOccurrences(of: "\\", with: "/") + "/"
                return normalized.lowercased().hasPrefix(base.lowercased()) ? String(normalized.dropFirst(base.count)) : nil
            })
            repos = [ChangedRepo(path: root, git: git, touched: files)]
            return
        }
        let found = await RepoDiscovery.find(on: session, folder: folder, touched: touched)
        let list = found.repos.map { ChangedRepo(path: $0, git: GitModel(session: session, folder: $0), touched: found.files[$0] ?? []) }
        repos = list
        await withTaskGroup(of: Void.self) { group in
            for git in list.map(\.git) { group.addTask { await git.refresh() } }
        }
    }

    private func refresh() async {
        guard let repos else { return }
        await withTaskGroup(of: Void.self) { group in
            for git in repos.map(\.git) { group.addTask { await git.refresh() } }
        }
    }
}

/// One repository's part of the changes: the chat's files, a commit box for them, and its other changes.
private struct RepoChangesSection: View {
    let repo: ChangedRepo
    /// Shown when there are several repositories.
    let title: String?
    let onDiff: (DiffRequest) -> Void
    let onRevert: (GitChange) -> Void

    @State private var message = ""
    @State private var pushAfter = false
    @State private var committed = false

    private var git: GitModel { repo.git }
    private var allChanges: [GitChange] { git.conflicts + git.staged + git.unstaged + git.untracked }

    /// This chat's files that git sees as changed, one row each.
    private var mine: [GitChange] {
        var seen = Set<String>()
        return allChanges.filter { repo.touched.contains($0.path) && seen.insert($0.path).inserted }
    }

    private var others: [GitChange] {
        var seen = Set(mine.map(\.path))
        return allChanges.filter { seen.insert($0.path).inserted }
    }

    var body: some View {
        if git.isLoading && allChanges.isEmpty {
            Section(title ?? "") { HStack { ProgressView(); Text("Reading changes…").foregroundStyle(.secondary) } }
        } else {
            if !repo.touched.isEmpty || title == nil {
                Section {
                    if mine.isEmpty {
                        Text(repo.touched.isEmpty ? "This chat hasn't changed files here." : "No uncommitted changes left from this chat.").foregroundStyle(.secondary)
                    }
                    ForEach(mine) { change in row(change) }
                } header: { header("Changed in this chat") } footer: {
                    if !mine.isEmpty { Text("Tap a file to see its diff. Swipe to revert it.") }
                }
            }

            if !mine.isEmpty {
                Section(title.map { "Commit to \($0)" } ?? "Commit") {
                    TextField("Commit message", text: $message, axis: .vertical).lineLimit(1...4)
                    Toggle("Push After Committing", isOn: $pushAfter)
                    Button(committed ? "Committed" : "Commit \(mine.count) \(mine.count == 1 ? "File" : "Files")") { Task { await commit() } }
                        .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || git.busy != nil || committed)
                }
            }

            if !others.isEmpty {
                Section { ForEach(others) { change in row(change) } } header: {
                    header(repo.touched.isEmpty && title != nil ? "Changes" : "Other changes")
                }
            }

            if let note = git.message {
                Section { Text(note).font(.footnote.monospaced()).foregroundStyle(.secondary) }
            }
        }
    }

    @ViewBuilder
    private func header(_ text: String) -> some View {
        if let title {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                Text(title).textCase(nil)
                if !git.branch.isEmpty { Text("· \(git.branch)").textCase(nil).foregroundStyle(.secondary) }
                Spacer()
                Text(text)
            }
        } else {
            Text(text)
        }
    }

    private func row(_ change: GitChange) -> some View {
        Button {
            onDiff(DiffRequest(title: change.fileName) { try await git.diff(for: change) })
        } label: {
            HStack(spacing: 10) {
                Text(String(change.status == "?" ? "A" : change.status))
                    .font(.caption.monospaced().weight(.bold)).foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(color(change), in: RoundedRectangle(cornerRadius: 5))
                VStack(alignment: .leading, spacing: 1) {
                    Text(change.fileName).foregroundStyle(.primary)
                    if !change.directory.isEmpty { Text(change.directory).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head) }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
            }
        }
        .swipeActions { Button("Revert", systemImage: "arrow.uturn.backward", role: .destructive) { onRevert(change) } }
    }

    private func color(_ change: GitChange) -> Color {
        switch change.status {
        case "D": .red
        case "?", "A": .green
        case "U": .purple
        default: .orange
        }
    }

    private func commit() async {
        await git.stage(mine.map(\.path))
        guard await git.commit(message: message.trimmingCharacters(in: .whitespacesAndNewlines), stageAllFirst: false) else { return }
        committed = true
        if pushAfter { await git.push() }
    }
}
