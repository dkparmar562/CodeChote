import SwiftUI

/// Native source control for the project folder.
struct GitTab: View {
    @Environment(AppModel.self) private var model
    let tabs: TabsModel
    @State private var git: GitModel?

    var body: some View {
        Group {
            if let git {
                GitContent(git: git, tabs: tabs)
            } else {
                ProgressView()
            }
        }
        .task(id: model.rootFolder) {
            guard let session = model.session else { return }
            let model = GitModel(session: session, folder: self.model.rootFolder)
            git = model
            await model.refresh()
        }
    }
}

private struct GitContent: View {
    @Bindable var git: GitModel
    let tabs: TabsModel
    @State private var commitMessage = ""
    @State private var showBranches = false
    @State private var newBranchName = ""
    @State private var creatingBranch = false
    @State private var discarding: GitChange?
    @State private var diff: DiffRequest?

    var body: some View {
        NavigationStack {
            Group {
                if git.notARepo {
                    ContentUnavailableView {
                        Label("Not a Git repository", systemImage: "arrow.triangle.branch")
                    } description: { Text("This folder isn't under version control.") } actions: {
                        Button("Initialize Repository") { Task { await git.initRepository() } }.buttonStyle(.borderedProminent)
                    }
                } else if git.repo == nil && git.isLoading {
                    ProgressView()
                } else {
                    list
                }
            }
            .navigationTitle("Source Control")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Fetch", systemImage: "arrow.down.circle") { Task { await git.fetch() } }
                        Button("Pull", systemImage: "arrow.down") { Task { await git.pull() } }
                        Button("Push", systemImage: "arrow.up") { Task { await git.push() } }
                        Divider()
                        Button("Refresh", systemImage: "arrow.clockwise") { Task { await git.refresh() } }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .refreshable { await git.refresh() }
            #if targetEnvironment(simulator)
            .onChange(of: git.unstaged.count) { _, _ in
                // `-devGitDiff`: open the first change's diff (simulator screenshots).
                if ProcessInfo.processInfo.arguments.contains("-devGitDiff"), diff == nil, let change = git.unstaged.first {
                    diff = DiffRequest(title: change.fileName) { try await git.diff(for: change) }
                }
            }
            #endif
            .overlay(alignment: .bottom) { if let busy = git.busy { busyPill(busy) } }
            .safeAreaInset(edge: .top, spacing: 0) { if let message = git.message { messageBar(message) } }
            .sheet(item: $diff) { request in DiffSheet(request: request) }
            .sheet(isPresented: $showBranches) { branchSheet }
            .confirmationDialog("Discard changes to “\(discarding?.fileName ?? "")”?", isPresented: Binding(get: { discarding != nil }, set: { if !$0 { discarding = nil } }), titleVisibility: .visible) {
                Button(discarding?.area == .untracked ? "Delete file" : "Discard changes", role: .destructive) {
                    if let change = discarding { Task { await git.discard(change) } }
                }
            } message: { Text("This can't be undone.") }
        }
    }

    // MARK: List

    private var list: some View {
        List {
            Section {
                Button { showBranches = true } label: {
                    HStack {
                        Image(systemName: "arrow.triangle.branch").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(git.branch.isEmpty ? "No branch" : git.branch).font(.headline).foregroundStyle(.primary)
                            if let upstream = git.upstream { Text(upstream).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        if git.ahead > 0 { Label("\(git.ahead)", systemImage: "arrow.up").font(.caption.weight(.semibold)) }
                        if git.behind > 0 { Label("\(git.behind)", systemImage: "arrow.down").font(.caption.weight(.semibold)) }
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                HStack(spacing: 10) {
                    syncButton("Pull", "arrow.down") { await git.pull() }
                    syncButton("Push", "arrow.up") { await git.push() }
                    syncButton("Fetch", "arrow.triangle.2.circlepath") { await git.fetch() }
                }
                .buttonStyle(.bordered)
            }

            Section("Commit") {
                TextField("Message", text: $commitMessage, axis: .vertical).lineLimit(1...5)
                HStack {
                    Button {
                        Task { if await git.commit(message: commitMessage, stageAllFirst: false) { commitMessage = "" } }
                    } label: { Text("Commit \(git.staged.count) staged").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
                    .disabled(commitMessage.trimmingCharacters(in: .whitespaces).isEmpty || git.staged.isEmpty || git.busy != nil)

                    Menu {
                        Button("Stage All and Commit", systemImage: "checkmark.circle") {
                            Task { if await git.commit(message: commitMessage, stageAllFirst: true) { commitMessage = "" } }
                        }
                    } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(.bordered)
                    .disabled(commitMessage.trimmingCharacters(in: .whitespaces).isEmpty || !git.hasChanges || git.busy != nil)
                }
            }

            if !git.conflicts.isEmpty { group("Merge conflicts", git.conflicts, tint: .red) }
            if !git.staged.isEmpty {
                group("Staged", git.staged, tint: .green, headerAction: ("Unstage All", { Task { await git.unstageAll() } }))
            }
            if !git.unstaged.isEmpty || !git.untracked.isEmpty {
                group("Changes", git.unstaged + git.untracked, tint: .orange, headerAction: ("Stage All", { Task { await git.stageAll() } }))
            }
            if !git.hasChanges && !git.isLoading {
                Section { Label("Working tree clean", systemImage: "checkmark.circle").foregroundStyle(.secondary) }
            }

            if !git.commits.isEmpty {
                Section("Recent commits") {
                    ForEach(git.commits) { commit in
                        Button {
                            diff = DiffRequest(title: commit.hash) { try await git.show(commit: commit) }
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(commit.subject).font(.subheadline).foregroundStyle(.primary).lineLimit(2)
                                Text("\(commit.hash) · \(commit.author) · \(commit.when)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func group(_ title: String, _ changes: [GitChange], tint: Color, headerAction: (String, () -> Void)? = nil) -> some View {
        Section {
            ForEach(changes) { change in
                Button {
                    diff = DiffRequest(title: change.fileName) { try await git.diff(for: change) }
                } label: {
                    HStack(spacing: 10) {
                        Text(String(change.status)).font(.caption.monospaced().bold()).foregroundStyle(.white)
                            .frame(width: 22, height: 22).background(tint, in: RoundedRectangle(cornerRadius: 6))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(change.fileName).foregroundStyle(.primary)
                            if !change.directory.isEmpty { Text(change.directory).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head) }
                        }
                    }
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .leading) {
                    if change.area == .staged {
                        Button { Task { await git.unstage([change.path]) } } label: { Label("Unstage", systemImage: "minus.circle") }.tint(.gray)
                    } else {
                        Button { Task { await git.stage([change.path]) } } label: { Label("Stage", systemImage: "plus.circle") }.tint(.green)
                    }
                }
                .swipeActions(edge: .trailing) {
                    if change.area != .staged {
                        Button(role: .destructive) { discarding = change } label: { Label("Discard", systemImage: "arrow.uturn.backward") }
                    }
                }
            }
        } header: {
            HStack {
                Text("\(title) (\(changes.count))")
                Spacer()
                if let headerAction { Button(headerAction.0, action: headerAction.1).font(.caption).textCase(nil) }
            }
        }
    }

    private func syncButton(_ title: String, _ symbol: String, _ action: @escaping () async -> Void) -> some View {
        Button { Task { await action() } } label: { Label(title, systemImage: symbol).frame(maxWidth: .infinity).font(.subheadline) }
            .disabled(git.busy != nil)
    }

    private func busyPill(_ text: String) -> some View {
        HStack(spacing: 8) { ProgressView().controlSize(.small); Text("\(text)…").font(.footnote.weight(.medium)) }
            .padding(.horizontal, 14).padding(.vertical, 10).glass(in: Capsule()).padding(.bottom, 90)
    }

    private func messageBar(_ text: String) -> some View {
        HStack(alignment: .top) {
            Text(text).font(.footnote).lineLimit(6).textSelection(.enabled)
            Spacer(minLength: 8)
            Button { git.message = nil } label: { Image(systemName: "xmark.circle.fill") }.foregroundStyle(.secondary)
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading).background(.thinMaterial)
    }

    private var branchSheet: some View {
        NavigationStack {
            List {
                Section("Branches") {
                    ForEach(git.branches, id: \.self) { name in
                        Button {
                            showBranches = false
                            Task { await git.switchBranch(name) }
                        } label: {
                            HStack { Text(name).foregroundStyle(.primary); Spacer(); if name == git.branch { Image(systemName: "checkmark") } }
                        }
                    }
                }
                Section {
                    Button("New Branch from Here…", systemImage: "plus") { creatingBranch = true }
                }
            }
            .navigationTitle("Branches")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { showBranches = false } } }
            .alert("New branch", isPresented: $creatingBranch) {
                TextField("Name", text: $newBranchName).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Create") {
                    let name = newBranchName.trimmingCharacters(in: .whitespaces)
                    newBranchName = ""
                    showBranches = false
                    if !name.isEmpty { Task { await git.createBranch(name) } }
                }
                Button("Cancel", role: .cancel) {}
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Diff

struct DiffRequest: Identifiable { let id = UUID(); let title: String; let load: () async throws -> String }

/// A unified diff, drawn with line numbers and colors. Works for one file or a whole commit.
struct DiffSheet: View {
    let request: DiffRequest
    @Environment(\.dismiss) private var dismiss
    @State private var lines: [DiffLine] = []
    @State private var state: LoadState = .loading
    enum LoadState { case loading, loaded, failed(String) }

    var body: some View {
        NavigationStack {
            Group {
                switch state {
                case .loading: ProgressView()
                case .failed(let message): ContentUnavailableView("Couldn't load the diff", systemImage: "exclamationmark.triangle", description: Text(message))
                case .loaded:
                    if lines.isEmpty {
                        ContentUnavailableView("No differences", systemImage: "checkmark.circle")
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(lines) { line in DiffRow(line: line) }
                            }
                            .padding(.bottom, 40)
                        }
                    }
                }
            }
            .navigationTitle(request.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
        .task {
            do {
                lines = DiffParser.parse(try await request.load())
                state = .loaded
            } catch { state = .failed((error as? LocalizedError)?.errorDescription ?? "\(error)") }
        }
    }
}

struct DiffLine: Identifiable {
    enum Kind { case file, hunk, added, removed, context, meta }
    let id: Int
    let kind: Kind
    let text: String
    let oldNumber: Int?
    let newNumber: Int?
}

enum DiffParser {
    static func parse(_ text: String, limit: Int = 6000) -> [DiffLine] {
        var result: [DiffLine] = []
        var oldN = 0, newN = 0
        var inHunk = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false).prefix(limit) {
            let line = String(raw)
            let id = result.count
            if line.hasPrefix("diff --git") || line.hasPrefix("diff --cc") {
                inHunk = false
                let name = line.components(separatedBy: " b/").last ?? line
                result.append(DiffLine(id: id, kind: .file, text: name, oldNumber: nil, newNumber: nil))
            } else if line.hasPrefix("@@") {
                inHunk = true
                // @@ -12,7 +12,8 @@ context
                let parts = line.split(separator: " ")
                if parts.count >= 3 {
                    oldN = Int(parts[1].dropFirst().split(separator: ",").first ?? "0") ?? 0
                    newN = Int(parts[2].dropFirst().split(separator: ",").first ?? "0") ?? 0
                }
                result.append(DiffLine(id: id, kind: .hunk, text: line, oldNumber: nil, newNumber: nil))
            } else if inHunk, line.hasPrefix("+") {
                result.append(DiffLine(id: id, kind: .added, text: String(line.dropFirst()), oldNumber: nil, newNumber: newN)); newN += 1
            } else if inHunk, line.hasPrefix("-") {
                result.append(DiffLine(id: id, kind: .removed, text: String(line.dropFirst()), oldNumber: oldN, newNumber: nil)); oldN += 1
            } else if inHunk, line.hasPrefix(" ") {
                result.append(DiffLine(id: id, kind: .context, text: String(line.dropFirst()), oldNumber: oldN, newNumber: newN)); oldN += 1; newN += 1
            } else if !line.hasPrefix("index ") && !line.hasPrefix("--- ") && !line.hasPrefix("+++ ") && !line.isEmpty {
                result.append(DiffLine(id: id, kind: .meta, text: line, oldNumber: nil, newNumber: nil))
            }
        }
        return result
    }
}

struct DiffRow: View {
    let line: DiffLine

    var body: some View {
        switch line.kind {
        case .file:
            Label(line.text, systemImage: "doc.text").font(.subheadline.weight(.semibold))
                .padding(.horizontal, 12).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.15))
        case .hunk:
            Text(line.text).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.blue.opacity(0.08))
        case .meta:
            Text(line.text).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 1)
        default:
            HStack(alignment: .top, spacing: 6) {
                Text(line.oldNumber.map(String.init) ?? "").frame(width: 30, alignment: .trailing)
                Text(line.newNumber.map(String.init) ?? "").frame(width: 30, alignment: .trailing)
                Text(marker).frame(width: 12)
                Text(line.text.isEmpty ? " " : line.text).frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: 12, design: .monospaced))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(background)
        }
    }

    private var marker: String { line.kind == .added ? "+" : line.kind == .removed ? "−" : "" }
    private var background: Color {
        switch line.kind {
        case .added: Color.green.opacity(0.18)
        case .removed: Color.red.opacity(0.18)
        default: .clear
        }
    }
}
