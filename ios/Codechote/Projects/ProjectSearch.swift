import SwiftUI

/// One line in the project that matched a search.
struct SearchMatch: Identifiable, Hashable {
    /// Relative to the folder searched.
    let path: String
    let line: Int
    let text: String
    var id: String { "\(path):\(line)" }
}

/// Searching file contents on the host: `git grep` in a repository (it skips ignored files and is fast),
/// `grep` elsewhere, PowerShell's Select-String on Windows. Plain text, not a pattern.
enum ProjectSearch {
    static let limit = 500

    static func run(_ query: String, in folder: String, matchCase: Bool, on session: SSHSession) async throws -> (matches: [SearchMatch], capped: Bool) {
        let output: String
        if session.os.isWindows {
            let script = """
            Set-Location -LiteralPath \(PS.quote(folder))
            Get-ChildItem -Recurse -File -ErrorAction SilentlyContinue |
              Where-Object { $_.FullName -notmatch '\\\\(\\.git|node_modules|\\.build|dist)\\\\' } |
              Select-String -SimpleMatch \(matchCase ? "-CaseSensitive " : "")-Pattern \(PS.quote(query)) -ErrorAction SilentlyContinue |
              Select-Object -First \(limit + 1) |
              ForEach-Object { "$(Resolve-Path -Relative $_.Path):$($_.LineNumber):$($_.Line)" }
            """
            output = try await session.exec(PS.encodedCommand(script)).stdout.replacingOccurrences(of: "\r\n", with: "\n")
        } else {
            let flags = matchCase ? "" : "-i"
            let script = """
            cd \(shellQuote(folder)) || exit 1
            q=\(shellQuote(query))
            if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
              git -c core.quotepath=off grep -n -I -F --untracked --no-color \(flags) -e "$q" -- .
            else
              grep -rnI -F \(flags) --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=.build --exclude-dir=dist -e "$q" .
            fi 2>/dev/null | head -n \(limit + 1)
            """
            output = try await session.exec("sh -c \(shellQuote(script))", maxBytes: 4_000_000).stdout
        }
        let matches = parse(output)
        return (Array(matches.prefix(limit)), matches.count > limit)
    }

    /// Reads `path:line:text` lines, as grep and git grep print them.
    nonisolated static func parse(_ output: String) -> [SearchMatch] {
        output.split(separator: "\n", omittingEmptySubsequences: true).compactMap { raw in
            let line = String(raw)
            guard let match = line.firstMatch(of: /^(?<path>.+?):(?<number>\d+):(?<text>.*)$/), let number = Int(match.number) else { return nil }
            var path = String(match.path).replacingOccurrences(of: "\\", with: "/")
            if path.hasPrefix("./") { path.removeFirst(2) }
            let text = String(match.text.prefix(300)).trimmingCharacters(in: .whitespaces)
            return SearchMatch(path: path, line: number, text: text)
        }
    }
}

/// Search in Files: results grouped by file; a result opens the file at that line.
struct ProjectSearchView: View {
    @Environment(AppModel.self) private var model
    let folder: String
    let tabs: TabsModel

    @State private var query = ""
    @State private var matchCase = false
    @State private var results: [SearchMatch] = []
    @State private var capped = false
    @State private var searching = false
    @State private var searched: String?
    @State private var errorText: String?

    private var groups: [(path: String, matches: [SearchMatch])] {
        var order: [String] = [], byPath: [String: [SearchMatch]] = [:]
        for match in results {
            if byPath[match.path] == nil { order.append(match.path) }
            byPath[match.path, default: []].append(match)
        }
        return order.map { ($0, byPath[$0]!) }
    }

    var body: some View {
        List {
            if let errorText {
                Label(errorText, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            } else if let searched, !searching {
                Section {
                    Text(summary(for: searched)).font(.footnote).foregroundStyle(.secondary)
                }
            }
            ForEach(groups, id: \.path) { group in
                Section {
                    ForEach(group.matches) { match in
                        Button { open(match) } label: { row(match) }.buttonStyle(.plain)
                    }
                } header: {
                    Label(group.path, systemImage: FileKind.symbol(for: group.path, isDirectory: false))
                        .textCase(nil).lineLimit(1).truncationMode(.head)
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if searching { ProgressView("Searching…") }
            else if searched == nil && results.isEmpty {
                ContentUnavailableView("Search in Files", systemImage: "magnifyingglass",
                                       description: Text("Finds text in every file of \(HostPath.lastComponent(folder)), skipping ignored ones."))
            }
        }
        .navigationTitle("Search")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Text to find")
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .onSubmit(of: .search) { Task { await search() } }
        #if targetEnvironment(simulator)
        .task {
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-devSearch"), i + 1 < args.count, searched == nil {
                query = args[i + 1]
                await search()
                if args.contains("-devSearchOpen"), let first = results.first { open(first) }
            }
        }
        #endif
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Toggle(isOn: $matchCase) { Image(systemName: "textformat") }
                    .toggleStyle(.button)
                    .accessibilityLabel("Match Case")
                    .onChange(of: matchCase) { _, _ in if searched != nil { Task { await search() } } }
            }
        }
    }

    private func summary(for text: String) -> String {
        if results.isEmpty { return "No matches for “\(text)”." }
        let files = groups.count
        let lines = results.count == 1 ? "1 line" : "\(results.count) lines"
        return "\(lines) in \(files == 1 ? "1 file" : "\(files) files")" + (capped ? ", showing the first \(ProjectSearch.limit). Search for something more specific to see the rest." : ".")
    }

    private func row(_ match: SearchMatch) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(verbatim: String(match.line)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(minWidth: 28, alignment: .trailing)
            Text(highlighted(match.text)).font(.system(size: 13, design: .monospaced)).lineLimit(2)
        }
        .contentShape(Rectangle())
    }

    private func highlighted(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        guard let searched, !searched.isEmpty else { return result }
        var start = text.startIndex
        let options: String.CompareOptions = matchCase ? [] : [.caseInsensitive]
        while let range = text.range(of: searched, options: options, range: start..<text.endIndex) {
            if let marked = Range(range, in: result) {
                result[marked].backgroundColor = Color.yellow.opacity(0.4)
                result[marked].font = .system(size: 13, weight: .semibold, design: .monospaced)
            }
            start = range.upperBound
        }
        return result
    }

    private func search() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, let session = model.session else { return }
        searching = true
        errorText = nil
        defer { searching = false }
        do {
            let found = try await ProjectSearch.run(text, in: folder, matchCase: matchCase, on: session)
            results = found.matches
            capped = found.capped
            searched = text
        } catch {
            errorText = "Couldn't search: \(describeError(error))"
        }
    }

    private func open(_ match: SearchMatch) {
        let path = HostPath.join(folder, match.path, windows: model.isWindowsHost)
        tabs.pendingLines[path] = match.line
        tabs.open(.file(path: path), title: (match.path as NSString).lastPathComponent, detail: path)
    }
}
