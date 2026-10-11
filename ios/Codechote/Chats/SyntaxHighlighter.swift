import UIKit

/// A small regex-based highlighter. It is not a parser: it colors comments, strings, numbers and
/// keywords well enough for reading and light edits on a phone. (Full language support is what the
/// VS Code tab is for.)
enum SyntaxHighlighter {

    struct Language {
        var keywords: [String] = []
        var lineComment: String? = "//"
        var blockComment: Bool = true
        var strings: [String] = ["\"", "'"]
    }

    static func language(for fileName: String) -> Language? {
        let ext = (fileName as NSString).pathExtension.lowercased()
        let cLike = ["if", "else", "for", "while", "do", "switch", "case", "break", "continue", "return", "static", "const", "struct", "class", "enum", "new", "delete", "public", "private", "protected", "void", "int", "long", "float", "double", "char", "bool", "true", "false", "null", "nullptr", "this", "try", "catch", "throw", "import", "package", "extends", "implements", "interface", "namespace", "using", "typedef", "sizeof", "include"]
        switch ext {
        case "swift":
            return Language(keywords: ["func", "let", "var", "if", "else", "guard", "return", "switch", "case", "default", "for", "in", "while", "repeat", "break", "continue", "struct", "class", "enum", "protocol", "extension", "import", "public", "private", "internal", "fileprivate", "open", "static", "final", "override", "init", "deinit", "self", "Self", "super", "nil", "true", "false", "try", "catch", "throw", "throws", "async", "await", "actor", "some", "any", "where", "as", "is", "typealias", "defer", "inout", "weak", "unowned", "lazy", "mutating", "@MainActor", "@State", "@Binding", "@Observable"])
        case "js", "jsx", "mjs", "cjs", "ts", "tsx":
            return Language(keywords: ["function", "const", "let", "var", "if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue", "return", "class", "extends", "new", "this", "super", "import", "export", "from", "as", "async", "await", "try", "catch", "finally", "throw", "typeof", "instanceof", "in", "of", "null", "undefined", "true", "false", "interface", "type", "enum", "implements", "public", "private", "protected", "readonly", "static", "void", "yield"], strings: ["\"", "'", "`"])
        case "py":
            return Language(keywords: ["def", "class", "if", "elif", "else", "for", "while", "return", "import", "from", "as", "try", "except", "finally", "raise", "with", "lambda", "pass", "break", "continue", "in", "is", "not", "and", "or", "None", "True", "False", "self", "async", "await", "yield", "global", "nonlocal", "del", "assert"], lineComment: "#", blockComment: false)
        case "go":
            return Language(keywords: ["func", "var", "const", "type", "struct", "interface", "map", "chan", "if", "else", "for", "range", "switch", "case", "default", "break", "continue", "return", "go", "defer", "select", "package", "import", "nil", "true", "false", "fallthrough"], strings: ["\"", "'", "`"])
        case "rs":
            return Language(keywords: ["fn", "let", "mut", "const", "static", "if", "else", "for", "while", "loop", "match", "return", "break", "continue", "struct", "enum", "impl", "trait", "pub", "use", "mod", "crate", "self", "Self", "super", "as", "in", "where", "async", "await", "move", "ref", "true", "false", "unsafe", "dyn", "type"])
        case "java", "kt", "kts", "cs", "scala":
            return Language(keywords: cLike + ["fun", "val", "var", "override", "abstract", "final", "object", "companion", "data", "sealed", "suspend", "is", "in", "when", "string", "String", "Int", "Boolean"])
        case "c", "h", "cpp", "hpp", "cc", "m", "mm":
            return Language(keywords: cLike + ["unsigned", "signed", "extern", "volatile", "inline", "template", "virtual", "operator", "auto", "#define", "#ifdef", "#ifndef", "#endif", "#else", "#pragma"])
        case "sh", "bash", "zsh", "fish":
            return Language(keywords: ["if", "then", "else", "elif", "fi", "for", "while", "do", "done", "case", "esac", "function", "return", "local", "export", "echo", "cd", "exit", "set", "unset", "in", "source"], lineComment: "#", blockComment: false)
        case "json":
            return Language(keywords: ["true", "false", "null"], lineComment: nil, blockComment: false, strings: ["\""])
        case "yml", "yaml", "toml", "ini", "env", "conf", "properties":
            return Language(keywords: ["true", "false", "null", "yes", "no"], lineComment: "#", blockComment: false)
        case "html", "xml", "svg", "plist":
            return Language(keywords: [], lineComment: nil, blockComment: false, strings: ["\"", "'"])
        case "css", "scss", "less":
            return Language(keywords: ["important", "media", "import", "from", "to"], strings: ["\"", "'"])
        case "rb":
            return Language(keywords: ["def", "end", "class", "module", "if", "elsif", "else", "unless", "while", "for", "do", "return", "require", "include", "nil", "true", "false", "self", "yield", "begin", "rescue", "ensure", "attr_accessor"], lineComment: "#", blockComment: false)
        case "php":
            return Language(keywords: ["function", "class", "public", "private", "protected", "static", "if", "else", "elseif", "foreach", "for", "while", "return", "new", "echo", "use", "namespace", "null", "true", "false", "try", "catch", "throw", "extends", "implements"])
        case "md", "markdown", "txt", "log":
            return Language(lineComment: nil, blockComment: false, strings: [])
        case "":
            return fileName.lowercased() == "dockerfile" || fileName.lowercased() == "makefile" ? Language(keywords: ["FROM", "RUN", "COPY", "CMD", "ENTRYPOINT", "ENV", "WORKDIR", "EXPOSE", "ARG"], lineComment: "#", blockComment: false) : nil
        default:
            return nil
        }
    }

    // Colors adapt to light and dark.
    private static let comment = UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.42, green: 0.60, blue: 0.40, alpha: 1) : UIColor(red: 0.20, green: 0.50, blue: 0.20, alpha: 1) }
    private static let string = UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.90, green: 0.60, blue: 0.45, alpha: 1) : UIColor(red: 0.77, green: 0.10, blue: 0.09, alpha: 1) }
    private static let number = UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.70, green: 0.80, blue: 0.55, alpha: 1) : UIColor(red: 0.10, green: 0.32, blue: 0.82, alpha: 1) }
    private static let keyword = UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.78, green: 0.52, blue: 0.85, alpha: 1) : UIColor(red: 0.67, green: 0.05, blue: 0.57, alpha: 1) }
    private static let heading = UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.45, green: 0.70, blue: 1.0, alpha: 1) : UIColor(red: 0.05, green: 0.30, blue: 0.75, alpha: 1) }

    static func apply(to storage: NSTextStorage, language: Language?, fileName: String, font: UIFont) {
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes([.font: font, .foregroundColor: UIColor.label], range: full)

        guard let language, storage.length < 400_000 else { storage.endEditing(); return }
        let text = storage.string

        func paint(_ pattern: String, _ color: UIColor, options: NSRegularExpression.Options = [], bold: Bool = false) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return }
            regex.enumerateMatches(in: text, options: [], range: full) { match, _, _ in
                guard let range = match?.range else { return }
                storage.addAttribute(.foregroundColor, value: color, range: range)
                if bold { storage.addAttribute(.font, value: UIFont.monospacedSystemFont(ofSize: font.pointSize, weight: .bold), range: range) }
            }
        }

        let ext = (fileName as NSString).pathExtension.lowercased()
        if ext == "md" || ext == "markdown" {
            paint("^#{1,6} .*$", heading, options: [.anchorsMatchLines], bold: true)
            paint("`[^`\\n]+`", string)
            paint("^```[\\s\\S]*?^```", comment, options: [.anchorsMatchLines])
            storage.endEditing()
            return
        }

        if !language.keywords.isEmpty {
            let words = language.keywords.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
            paint("(?<![\\w])(?:\(words))(?![\\w])", keyword)
        }
        paint("\\b0x[0-9A-Fa-f]+\\b|\\b\\d+(?:\\.\\d+)?\\b", number)
        for quote in language.strings {
            let q = NSRegularExpression.escapedPattern(for: quote)
            paint("\(q)(?:\\\\.|[^\(q)\\\\\\n])*\(q)", string)
        }
        if language.blockComment { paint("/\\*[\\s\\S]*?\\*/", comment) }
        if ext == "html" || ext == "xml" || ext == "svg" { paint("<!--[\\s\\S]*?-->", comment) }
        if let line = language.lineComment {
            // Not inside a string: require the marker at line start or after whitespace/code, which is
            // good enough here.
            paint("(?<![:\"'\\w])\(NSRegularExpression.escapedPattern(for: line))[^\\n]*", comment)
        }
        storage.endEditing()
    }
}
