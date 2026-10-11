import SwiftUI
import UIKit

// MARK: - Where a chat's files live

private struct ChatHostKey: EnvironmentKey { static let defaultValue: SSHSession? = nil }
private struct ChatFolderKey: EnvironmentKey { static let defaultValue = "" }

extension EnvironmentValues {
    /// The host a conversation runs on, so its tool cards can open the files they mention.
    var chatHost: SSHSession? {
        get { self[ChatHostKey.self] }
        set { self[ChatHostKey.self] = newValue }
    }
    /// The conversation's project folder, for relative paths.
    var chatFolder: String {
        get { self[ChatFolderKey.self] }
        set { self[ChatFolderKey.self] = newValue }
    }
}

// MARK: - Reading tool input and output

enum ToolText {
    /// The input of a call as a dictionary.
    static func input(_ call: ToolCall) -> [String: Any] { AgentJSON.object(call.inputJSON) ?? [:] }

    /// The file a call is about, if any.
    static func path(_ call: ToolCall) -> String? {
        let input = input(call)
        return (input["file_path"] as? String) ?? (input["notebook_path"] as? String) ?? (input["path"] as? String)
    }

    /// Claude Code's Read output numbers each line (`     12→text` or `12\ttext`) and may end with notes for the
    /// model. Returns the first line number and the bare text.
    static func stripLineNumbers(_ text: String) -> (start: Int, content: String) {
        var body = text
        if let range = body.range(of: "\n<system-reminder>") { body = String(body[..<range.lowerBound]) }
        let lines = body.components(separatedBy: "\n")
        let pattern = try? NSRegularExpression(pattern: #"^\s*(\d+)(→|\t)"#)
        var start: Int?
        var out: [String] = []
        var numbered = 0
        for line in lines {
            let ns = line as NSString
            if let match = pattern?.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                if start == nil { start = Int(ns.substring(with: match.range(at: 1))) }
                out.append(ns.substring(from: match.range.length))
                numbered += 1
            } else {
                out.append(line)
            }
        }
        // Only treat it as numbered when most lines were.
        guard let start, numbered * 2 >= lines.count else { return (1, body) }
        while out.last?.isEmpty == true { out.removeLast() }
        return (start, out.joined(separator: "\n"))
    }

    /// A line-by-line diff (longest common subsequence), for showing edits.
    enum DiffLine: Equatable { case same(String), removed(String), added(String) }

    static func diff(_ old: String, _ new: String) -> [DiffLine] {
        let a = old.components(separatedBy: "\n"), b = new.components(separatedBy: "\n")
        guard a.count * b.count <= 4_000_000 else { return a.map { .removed($0) } + b.map { .added($0) } }
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var i = 0, j = 0, result: [DiffLine] = []
        while i < a.count && j < b.count {
            if a[i] == b[j] { result.append(.same(a[i])); i += 1; j += 1 }
            else if table[i + 1][j] >= table[i][j + 1] { result.append(.removed(a[i])); i += 1 }
            else { result.append(.added(b[j])); j += 1 }
        }
        result += a[i...].map { .removed($0) } + b[j...].map { .added($0) }
        return result
    }
}

// MARK: - The detail screen

/// Everything about one tool call, readable on a phone: files with highlighting (Markdown rendered), edits as a
/// diff, commands with their output, images.
struct ToolDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.chatHost) private var host
    @Environment(\.chatFolder) private var folder
    let call: ToolCall
    @State private var openingFile = false

    private var input: [String: Any] { ToolText.input(call) }
    private var path: String? { ToolText.path(call) }
    private var fileName: String { path.map { ($0 as NSString).lastPathComponent } ?? call.name }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(path != nil ? fileName : call.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            if path != nil, host != nil { Button("Open Current File", systemImage: "doc") { openingFile = true } }
                            if let path { Button("Copy Path", systemImage: "doc.on.doc") { UIPasteboard.general.string = path } }
                            if let result = call.result { Button("Copy Output", systemImage: "doc.on.clipboard") { UIPasteboard.general.string = result } }
                            Button("Copy Input", systemImage: "curlybraces") { UIPasteboard.general.string = call.inputJSON }
                        } label: { Image(systemName: "ellipsis.circle") }
                    }
                }
                .sheet(isPresented: $openingFile) {
                    if let path, let host { HostFileView(session: host, path: resolved(path)) }
                }
        }
    }

    private func resolved(_ path: String) -> String {
        path.hasPrefix("/") || path.dropFirst().first == ":" || folder.isEmpty ? path : folder + "/" + path
    }

    @ViewBuilder private var content: some View {
        switch call.name {
        case "Read":
            if let path, FileKind.isImage(path), let host {
                HostFileView(session: host, path: resolved(path), embedded: true)
            } else if let result = call.result {
                let stripped = ToolText.stripLineNumbers(result)
                FileContentView(name: fileName, text: stripped.content, firstLine: stripped.start, header: path)
            } else { waiting }
        case "Write":
            FileContentView(name: fileName, text: input["content"] as? String ?? "", firstLine: 1, header: path.map { "New contents of \($0)" })
        case "Edit":
            DiffView(header: path, hunks: [(input["old_string"] as? String ?? "", input["new_string"] as? String ?? "")], error: call.isError ? call.result : nil)
        case "MultiEdit":
            let edits = (input["edits"] as? [[String: Any]] ?? []).map { ($0["old_string"] as? String ?? "", $0["new_string"] as? String ?? "") }
            DiffView(header: path, hunks: edits, error: call.isError ? call.result : nil)
        case "Bash":
            CommandView(command: input["command"] as? String ?? call.summary, description: input["description"] as? String, output: call.result, isError: call.isError)
        default:
            GenericToolView(call: call)
        }
    }

    private var waiting: some View {
        VStack(spacing: 10) { ProgressView(); Text("Still running…").font(.footnote).foregroundStyle(.secondary) }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A file's text: Markdown can be read rendered or as source; everything else is highlighted, with line numbers.
struct FileContentView: View {
    let name: String
    let text: String
    var firstLine = 1
    var header: String?
    @State private var showSource = false

    private var isMarkdown: Bool { ["md", "markdown", "mdx"].contains((name as NSString).pathExtension.lowercased()) }

    var body: some View {
        VStack(spacing: 0) {
            if isMarkdown {
                Picker("View", selection: $showSource) {
                    Text("Preview").tag(false)
                    Text("Source").tag(true)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16).padding(.vertical, 8)
            }
            if let header {
                Text(header).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2).truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.bottom, 6)
            }
            if text.isEmpty {
                ContentUnavailableView("Empty", systemImage: "doc", description: Text("Nothing to show."))
            } else if isMarkdown && !showSource {
                ScrollView { MarkdownView(text: text).padding(16) }
            } else {
                CodeText(text: text, fileName: name, firstLine: firstLine)
            }
        }
    }
}

/// Highlighted, selectable code with line numbers. Long lines wrap, as they do on a phone.
struct CodeText: UIViewRepresentable {
    let text: String
    let fileName: String
    var firstLine = 1

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.backgroundColor = .systemBackground
        view.textContainerInset = UIEdgeInsets(top: 8, left: 6, bottom: 24, right: 8)
        view.alwaysBounceVertical = true
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        guard context.coordinator.shown != text else { return }
        context.coordinator.shown = text
        view.attributedText = Self.attributed(text, fileName: fileName, firstLine: firstLine)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var shown: String? }

    static func attributed(_ text: String, fileName: String, firstLine: Int) -> NSAttributedString {
        let font = UIFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        let lines = text.components(separatedBy: "\n")
        let width = String(firstLine + lines.count).count
        // Highlight the code alone, then put a dim number in front of each line.
        let code = NSTextStorage(string: text)
        SyntaxHighlighter.apply(to: code, language: SyntaxHighlighter.language(for: fileName), fileName: fileName, font: font)
        let paragraph = NSMutableParagraphStyle()
        let gutter = CGFloat(width + 2) * font.pointSize * 0.62
        paragraph.headIndent = gutter              // wrapped lines line up with the code, not the number
        paragraph.lineBreakMode = .byCharWrapping
        let out = NSMutableAttributedString()
        var location = 0
        for (index, line) in lines.enumerated() {
            let number = String(firstLine + index)
            out.append(NSAttributedString(string: String(repeating: " ", count: width - number.count) + number + "  ",
                                          attributes: [.font: font, .foregroundColor: UIColor.tertiaryLabel]))
            let length = (line as NSString).length
            out.append(code.attributedSubstring(from: NSRange(location: location, length: length)))
            if index < lines.count - 1 { out.append(NSAttributedString(string: "\n", attributes: [.font: font])) }
            location += length + 1
        }
        out.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: out.length))
        return out
    }
}

/// An edit as removed and added lines.
struct DiffView: View {
    let header: String?
    let hunks: [(String, String)]
    let error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let header { Text(header).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2).truncationMode(.head) }
                if let error { Label(error, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.red) }
                ForEach(Array(hunks.enumerated()), id: \.offset) { index, hunk in
                    if hunks.count > 1 { Text("Change \(index + 1)").font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(ToolText.diff(hunk.0, hunk.1).enumerated()), id: \.offset) { _, line in row(line) }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.2)) }
                }
            }
            .padding(16)
        }
    }

    private func row(_ line: ToolText.DiffLine) -> some View {
        let (sign, text, color): (String, String, Color) = {
            switch line {
            case .same(let t): (" ", t, .clear)
            case .removed(let t): ("−", t, .red)
            case .added(let t): ("+", t, .green)
            }
        }()
        return HStack(alignment: .top, spacing: 6) {
            Text(sign).foregroundStyle(color == .clear ? Color.secondary : color).frame(width: 12)
            Text(text.isEmpty ? " " : text).frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 12.5, design: .monospaced))
        .textSelection(.enabled)
        .padding(.horizontal, 8).padding(.vertical, 1.5)
        .background(color.opacity(0.14))
    }
}

/// A command and what it printed, in terminal colours.
struct CommandView: View {
    let command: String
    let description: String?
    let output: String?
    let isError: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let description, !description.isEmpty { Text(description).font(.subheadline).foregroundStyle(.secondary) }
                Text("$ " + command)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                if let output {
                    Text(output.isEmpty ? "(no output)" : output)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(isError ? Color(red: 1, green: 0.55, blue: 0.5) : Color(white: 0.88))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color(red: 0.08, green: 0.09, blue: 0.11), in: RoundedRectangle(cornerRadius: 10))
                } else {
                    HStack { ProgressView(); Text("Running…").foregroundStyle(.secondary) }
                }
            }
            .padding(16)
        }
    }
}

/// Any other tool: its input fields and its result.
struct GenericToolView: View {
    let call: ToolCall

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                let input = ToolText.input(call)
                if !input.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(input.keys.sorted(), id: \.self) { key in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(key).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                Text(describe(input[key])).font(.system(size: 12.5, design: .monospaced)).textSelection(.enabled)
                            }
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                }
                if let result = call.result {
                    Text(call.isError ? "Error" : "Result").font(.caption.weight(.semibold)).foregroundStyle(call.isError ? .red : .secondary)
                    if looksLikeMarkdown(result) {
                        MarkdownView(text: result)
                    } else {
                        Text(result).font(.system(size: 12.5, design: .monospaced)).textSelection(.enabled)
                            .foregroundStyle(call.isError ? .red : .primary)
                    }
                }
            }
            .padding(16)
        }
    }

    private func describe(_ value: Any?) -> String {
        if let s = value as? String { return s }
        return AgentJSON.prettyJSON(value).nonEmpty ?? String(describing: value ?? "")
    }

    private func looksLikeMarkdown(_ text: String) -> Bool { text.contains("\n# ") || text.hasPrefix("#") || text.contains("\n- ") || text.contains("**") }
}

/// A file read from the host as it is now: images shown, text highlighted, Markdown rendered.
struct HostFileView: View {
    @Environment(\.dismiss) private var dismiss
    let session: SSHSession
    let path: String
    var embedded = false

    private enum Loaded { case loading, image(UIImage), text(String, truncated: Bool), failed(String) }
    @State private var loaded: Loaded = .loading

    var body: some View {
        if embedded { content } else {
            NavigationStack {
                content
                    .navigationTitle((path as NSString).lastPathComponent)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            }
        }
    }

    @ViewBuilder private var content: some View {
        Group {
            switch loaded {
            case .loading: ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .image(let image):
                ZoomableImage(image: image).ignoresSafeArea(edges: .bottom)
            case .text(let text, let truncated):
                FileContentView(name: (path as NSString).lastPathComponent, text: text, firstLine: 1, header: truncated ? "\(path) (first 2 MB)" : path)
            case .failed(let message):
                ContentUnavailableView("Couldn't open it", systemImage: "exclamationmark.triangle", description: Text(message))
            }
        }
        .task {
            do {
                let (data, truncated) = try await session.readFile(path, limit: 2_000_000)
                if FileKind.isImage(path), let image = UIImage(data: data) { loaded = .image(image) }
                else if let text = String(data: data, encoding: .utf8) { loaded = .text(text, truncated: truncated) }
                else { loaded = .failed("It isn't text or an image (\(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))).") }
            } catch {
                loaded = .failed((error as? LocalizedError)?.errorDescription ?? "\(error)")
            }
        }
    }
}
