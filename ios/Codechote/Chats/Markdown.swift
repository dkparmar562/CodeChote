import SwiftUI

/// A compact Markdown renderer for chat replies: paragraphs, headings, lists, quotes, rules, tables and
/// fenced code. Inline styling (bold, italic, `code`, links) comes from AttributedString.
enum MDBlock: Identifiable {
    case paragraph(String)
    case heading(Int, String)
    case code(String?, String)
    case bullets([String])
    case numbered([String])
    case quote(String)
    case table(MDTable)
    case rule

    var id: String {
        switch self {
        case .paragraph(let t): "p\(t.hashValue)"
        case .heading(let l, let t): "h\(l)\(t.hashValue)"
        case .code(_, let c): "c\(c.hashValue)"
        case .bullets(let i): "b\(i.joined().hashValue)"
        case .numbered(let i): "n\(i.joined().hashValue)"
        case .quote(let t): "q\(t.hashValue)"
        case .table(let t): "t\(t.hashValue)"
        case .rule: "rule"
        }
    }

    /// Parsed replies, so redrawing a long chat doesn't parse every message again.
    private static let cache: NSCache<NSString, Parsed> = {
        let cache = NSCache<NSString, Parsed>()
        cache.countLimit = 400
        return cache
    }()

    private final class Parsed {
        let blocks: [MDBlock]
        init(_ blocks: [MDBlock]) { self.blocks = blocks }
    }

    /// `parse`, remembered for text seen before.
    static func cached(_ text: String) -> [MDBlock] {
        if let hit = cache.object(forKey: text as NSString) { return hit.blocks }
        let blocks = parse(text)
        cache.setObject(Parsed(blocks), forKey: text as NSString)
        return blocks
    }

    static func parse(_ text: String) -> [MDBlock] {
        var blocks: [MDBlock] = []
        var paragraph: [String] = []
        var bullets: [String] = [], numbered: [String] = [], quote: [String] = []
        var code: [String]?, codeLang: String?

        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
            if !bullets.isEmpty { blocks.append(.bullets(bullets)); bullets = [] }
            if !numbered.isEmpty { blocks.append(.numbered(numbered)); numbered = [] }
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))); quote = [] }
        }

        let lines = text.components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            let line = lines[index]
            index += 1
            if code != nil {
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    blocks.append(.code(codeLang, code!.joined(separator: "\n"))); code = nil; codeLang = nil
                } else { code!.append(line) }
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                flush(); code = []
                codeLang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces).nonEmpty
            } else if trimmed.isEmpty {
                flush()
            } else if trimmed.contains("|"), index < lines.count, let alignments = MDTable.separator(lines[index]) {
                // A header row followed by `|---|:--:|`; the rows run until a line without a pipe.
                flush()
                var rows: [[String]] = []
                index += 1
                while index < lines.count {
                    let row = lines[index].trimmingCharacters(in: .whitespaces)
                    guard row.contains("|") else { break }
                    rows.append(MDTable.cells(row))
                    index += 1
                }
                blocks.append(.table(MDTable(header: MDTable.cells(trimmed), alignments: alignments, rows: rows)))
            } else if let level = headingLevel(trimmed) {
                flush(); blocks.append(.heading(level, String(trimmed.dropFirst(level + 1))))
            } else if trimmed == "---" || trimmed == "***" {
                flush(); blocks.append(.rule)
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("• ") {
                if !paragraph.isEmpty || !numbered.isEmpty || !quote.isEmpty { flush() }
                bullets.append(String(trimmed.dropFirst(2)))
            } else if let range = trimmed.range(of: #"^\d+[.)] "#, options: .regularExpression) {
                if !paragraph.isEmpty || !bullets.isEmpty || !quote.isEmpty { flush() }
                numbered.append(String(trimmed[range.upperBound...]))
            } else if trimmed.hasPrefix("> ") {
                if !paragraph.isEmpty || !bullets.isEmpty || !numbered.isEmpty { flush() }
                quote.append(String(trimmed.dropFirst(2)))
            } else {
                if !bullets.isEmpty || !numbered.isEmpty || !quote.isEmpty { flush() }
                paragraph.append(line)
            }
        }
        if let code { blocks.append(.code(codeLang, code.joined(separator: "\n"))) }   // an unterminated fence while streaming
        flush()
        return blocks
    }

    private static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix { $0 == "#" }.count
        return (1...6).contains(hashes) && line.dropFirst(hashes).hasPrefix(" ") ? hashes : nil
    }
}

/// A GitHub-style table: a header row, each column's alignment, and the body rows (padded to the header's width).
struct MDTable: Hashable {
    enum Alignment: Hashable { case leading, center, trailing }
    let header: [String]
    let alignments: [Alignment]
    let rows: [[String]]

    init(header: [String], alignments: [Alignment], rows: [[String]]) {
        let width = header.count
        self.header = header
        self.alignments = (0..<width).map { $0 < alignments.count ? alignments[$0] : .leading }
        self.rows = rows.map { row in (0..<width).map { $0 < row.count ? row[$0] : "" } }
    }

    /// The cells of a row such as `| a | b |`, keeping `\|` as a literal pipe.
    nonisolated static func cells(_ line: String) -> [String] {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("|") { text.removeFirst() }
        if text.hasSuffix("|") && !text.hasSuffix("\\|") { text.removeLast() }
        var cells: [String] = [], current = "", escaped = false
        for character in text {
            if escaped { if character != "|" { current.append("\\") }; current.append(character); escaped = false }
            else if character == "\\" { escaped = true }
            else if character == "|" { cells.append(current.trimmingCharacters(in: .whitespaces)); current = "" }
            else { current.append(character) }
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    /// The column alignments when `line` is a separator row such as `|---|:--:|--:|`, otherwise nil.
    nonisolated static func separator(_ line: String) -> [Alignment]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-"), trimmed.allSatisfy({ "|:- \t".contains($0) }) else { return nil }
        let parts = cells(trimmed)
        guard !parts.isEmpty, parts.allSatisfy({ $0.contains("-") }) else { return nil }
        return parts.map { part in
            switch (part.hasPrefix(":"), part.hasSuffix(":")) {
            case (true, true): .center
            case (false, true): .trailing
            default: .leading
            }
        }
    }
}

struct MarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // By position: two identical paragraphs (or rules) in one reply would share a content-based id.
            ForEach(Array(MDBlock.cached(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let t): inline(t)
                case .heading(let level, let t):
                    inline(t).font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                case .code(let lang, let code): CodeBlock(language: lang, code: code)
                case .bullets(let items):
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .firstTextBaseline, spacing: 8) { Text("•"); inline(item) }
                        }
                    }
                case .numbered(let items):
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                            HStack(alignment: .firstTextBaseline, spacing: 8) { Text("\(index + 1).").monospacedDigit().foregroundStyle(.secondary); inline(item) }
                        }
                    }
                case .quote(let t):
                    inline(t).foregroundStyle(.secondary).padding(.leading, 10)
                        .overlay(alignment: .leading) { Rectangle().fill(Color.secondary.opacity(0.4)).frame(width: 3) }
                case .table(let table): MarkdownTable(table: table)
                case .rule: Divider()
                }
            }
        }
        .textSelection(.enabled)
    }

    private func inline(_ markdown: String) -> some View {
        Text(Self.attributed(markdown)).frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Inline Markdown (bold, italic, `code`, links) as styled text.
    static func attributed(_ markdown: String) -> AttributedString {
        var text = (try? AttributedString(markdown: markdown, options: .init(allowsExtendedAttributes: true, interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(markdown)
        linkify(&text)
        // Inline `code`: monospaced a step smaller (it reads larger than the text around it), on a light tint.
        for run in text.runs where run.inlinePresentationIntent?.contains(.code) == true {
            text[run.range].font = .system(.callout, design: .monospaced)
            text[run.range].backgroundColor = Color.secondary.opacity(0.14)
        }
        return text
    }

    /// Full addresses, and the `localhost:3000` kind that agents print for the dev servers they start.
    private static let addressPattern = try! NSRegularExpression(
        pattern: #"\b(?:https?://[^\s<>()\[\]`'"]+|(?:localhost|127\.0\.0\.1|0\.0\.0\.0):\d{2,5}(?:/[^\s<>()\[\]`'"]*)?)"#)

    /// Makes plain addresses tappable, also inside `code`. Markdown only links `[text](url)` and `<url>`.
    nonisolated static func linkify(_ text: inout AttributedString) {
        let plain = String(text.characters)
        let whole = NSRange(plain.startIndex..., in: plain)
        for match in addressPattern.matches(in: plain, range: whole).reversed() {
            guard var found = Range(match.range, in: plain) else { continue }
            // Punctuation at the end belongs to the sentence ("open localhost:3000.").
            while found.lowerBound < found.upperBound, let last = plain[found].last, ".,;:!?".contains(last) {
                found = found.lowerBound..<plain.index(before: found.upperBound)
            }
            guard let range = Range(found, in: text), !text[range].runs.contains(where: { $0.link != nil }) else { continue }
            var address = String(plain[found])
            if !address.contains("://") { address = "http://" + address }
            // 0.0.0.0 is how servers say "every address"; to visit one, use localhost.
            address = address.replacingOccurrences(of: "://0.0.0.0", with: "://localhost")
            if let url = URL(string: address) { text[range].link = url }
        }
    }
}

/// A table in a reply: bordered, with a shaded header row, and scrolled sideways when it's wider than the screen.
/// Long cells wrap instead of stretching their column.
struct MarkdownTable: View {
    let table: MDTable

    /// Each column's width, from its longest cell (estimated from its length), between a narrow minimum
    /// and a cap past which cells wrap. Fixed widths let each row grow to fit its wrapped cells.
    private var widths: [CGFloat] {
        table.header.indices.map { column in
            let longest = ([table.header[column]] + table.rows.map { $0[column] })
                .map { $0.replacingOccurrences(of: "**", with: "").count }.max() ?? 0
            return min(max(CGFloat(longest) * 8.6 + 22, 56), 240)
        }
    }

    var body: some View {
        let widths = widths
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(table.header.indices, id: \.self) { column in
                        cell(table.header[column], width: widths[column], column: column).fontWeight(.semibold)
                    }
                }
                .background(Color.secondary.opacity(0.12))
                ForEach(table.rows.indices, id: \.self) { row in
                    Divider()
                    GridRow {
                        ForEach(table.header.indices, id: \.self) { column in cell(table.rows[row][column], width: widths[column], column: column) }
                    }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.25)))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    }

    private func cell(_ text: String, width: CGFloat, column: Int) -> some View {
        let alignment: Alignment = switch table.alignments[column] {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
        return Text(MarkdownView.attributed(text))
            .font(.subheadline)
            .multilineTextAlignment(alignment == .trailing ? .trailing : alignment == .center ? .center : .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(width: width, alignment: alignment)
            .gridColumnAlignment(alignment == .trailing ? .trailing : alignment == .center ? .center : .leading)
    }
}

struct CodeBlock: View {
    let language: String?
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? "code").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button { UIPasteboard.general.string = code } label: { Image(systemName: "doc.on.doc").font(.caption) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Copy code")
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.secondary.opacity(0.12))
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code).font(.system(size: 12.5, design: .monospaced)).padding(10).fixedSize(horizontal: true, vertical: true)
            }
        }
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
