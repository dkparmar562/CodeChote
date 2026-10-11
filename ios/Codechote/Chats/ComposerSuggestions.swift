import Observation
import SwiftUI

/// What can be suggested while typing: slash commands (Claude Code's custom commands, from the project and the
/// home folder) after a leading "/", and project files after "@". Read from the host once, when first needed.
@MainActor
@Observable
final class ComposerIndex {
    struct Command: Identifiable, Equatable { let name: String; let detail: String; var id: String { name } }

    private(set) var commands: [Command] = []
    private(set) var files: [String] = []
    private var loadedCommands = false
    private var loadedFiles = false

    enum Suggestion: Equatable { case command(Command), file(String) }

    /// Suggestions for the text being typed, best first.
    func suggestions(for input: String) -> [Suggestion] {
        if input.hasPrefix("/"), !input.contains(" "), !input.contains("\n") {
            let query = input.dropFirst().lowercased()
            return commands.filter { query.isEmpty || $0.name.lowercased().contains(query) }.prefix(8).map { .command($0) }
        }
        if let token = Self.mentionToken(in: input) {
            let query = token.lowercased()
            let matches = files.filter { query.isEmpty || $0.lowercased().contains(query) }
            // Names that start with the query first, then shorter paths.
            let ranked = matches.sorted { a, b in
                let aStarts = (a as NSString).lastPathComponent.lowercased().hasPrefix(query)
                let bStarts = (b as NSString).lastPathComponent.lowercased().hasPrefix(query)
                return aStarts != bStarts ? aStarts : a.count < b.count
            }
            return ranked.prefix(8).map { .file($0) }
        }
        return []
    }

    /// The text after an "@" at the end of the input ("look at @src/ma" → "src/ma").
    static func mentionToken(in input: String) -> String? {
        guard let at = input.lastIndex(of: "@") else { return nil }
        let before = input[..<at]
        guard before.isEmpty || before.last?.isWhitespace == true else { return nil }   // not an email address
        let token = input[input.index(after: at)...]
        return token.contains(where: \.isWhitespace) ? nil : String(token)
    }

    /// The input with the suggestion put in place of what was being typed.
    static func apply(_ suggestion: Suggestion, to input: String) -> String {
        switch suggestion {
        case .command(let command): return "/\(command.name) "
        case .file(let path):
            guard let at = input.lastIndex(of: "@") else { return input + "@" + path + " " }
            return String(input[..<at]) + "@" + path + " "
        }
    }

    func prepare(for input: String, agent: AgentKind, folder: String, session: SSHSession) async {
        guard !session.os.isWindows else { return }
        if input.hasPrefix("/"), !loadedCommands, agent == .claude {
            loadedCommands = true
            let script = """
            for f in \(shellQuote(folder))/.claude/commands/*.md "$HOME"/.claude/commands/*.md; do
              [ -f "$f" ] || continue
              d=$(grep -m1 -E '^description:' "$f" 2>/dev/null | cut -d: -f2- | sed 's/^ *//')
              [ -n "$d" ] || d=$(grep -m1 -v -E '^(---|$)' "$f" 2>/dev/null | cut -c1-120)
              printf '%s\\t%s\\n' "$(basename "$f" .md)" "$d"
            done
            """
            if let result = try? await session.exec("sh -c \(shellQuote(script))") {
                var seen = Set<String>()
                commands = result.stdout.split(separator: "\n").compactMap { line in
                    let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
                    guard let name = parts.first, !name.isEmpty, seen.insert(name).inserted else { return nil }
                    return Command(name: name, detail: parts.count > 1 ? parts[1] : "")
                }
            }
        }
        if Self.mentionToken(in: input) != nil, !loadedFiles {
            loadedFiles = true
            let script = "cd \(shellQuote(folder)) && { git ls-files -co --exclude-standard 2>/dev/null || find . -type f -not -path '*/.git/*' -not -path '*/node_modules/*' | sed 's#^\\./##'; } | head -5000"
            if let result = try? await session.exec("sh -c \(shellQuote(script))") {
                files = result.stdout.split(separator: "\n").map(String.init)
            }
        }
    }
}

/// The list shown above the message box while typing "/" or "@".
struct SuggestionList: View {
    let suggestions: [ComposerIndex.Suggestion]
    let onPick: (ComposerIndex.Suggestion) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.offset) { index, suggestion in
                Button { onPick(suggestion) } label: {
                    HStack(spacing: 10) {
                        switch suggestion {
                        case .command(let command):
                            Image(systemName: "slash.circle").foregroundStyle(Color.accentColor)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("/" + command.name).font(.subheadline.monospaced().weight(.medium)).foregroundStyle(.primary)
                                if !command.detail.isEmpty { Text(command.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                            }
                        case .file(let path):
                            Image(systemName: FileKind.symbol(for: path, isDirectory: false)).foregroundStyle(.secondary).frame(width: 20)
                            VStack(alignment: .leading, spacing: 1) {
                                Text((path as NSString).lastPathComponent).font(.subheadline).foregroundStyle(.primary)
                                let dir = (path as NSString).deletingLastPathComponent
                                if !dir.isEmpty { Text(dir).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head) }
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if index < suggestions.count - 1 { Divider().padding(.leading, 44) }
            }
        }
        .glass(in: RoundedRectangle(cornerRadius: 18))
        .padding(.horizontal, 12)
    }
}
