import Foundation

struct HostFileError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// File operations on the host, done with ordinary shell tools so they work on any Linux or macOS box.
extension SSHSession {

    /// Reads a file (binary-safe, through base64). Files bigger than `limit` come back truncated.
    func readFile(_ path: String, limit: Int = 2_000_000) async throws -> (data: Data, truncated: Bool) {
        let result: CommandResult
        if os.isWindows {
            result = try await powershell("read", vars: ["Path": .string(path), "Limit": .string(String(limit))])
        } else {
            result = try await exec("head -c \(limit + 1) -- \(shellQuote(path)) | base64", maxBytes: limit * 2 + 4096)
        }
        guard result.succeeded else { throw HostFileError(message: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "Couldn't read \(path)") }
        let data = Data(base64Encoded: result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), options: .ignoreUnknownCharacters) ?? Data()
        return data.count > limit ? (data.prefix(limit), true) : (data, false)
    }

    /// Writes a file in chunks (a single command line can only be so long), then moves it into place so a
    /// dropped connection never leaves a half-written file.
    func writeFile(_ path: String, data: Data) async throws {
        let temp = path + ".cc-tmp"
        if os.isWindows {
            // Command lines on Windows are short, so chunks are small.
            var offset = 0, first = true
            repeat {
                let slice = data[offset..<min(offset + 1500, data.count)]
                _ = try await runWindows("append", ["Path": .string(temp), "Data": .string(slice.base64EncodedString()), "Truncate": .string(first ? "true" : "false")])
                offset += 1500; first = false
            } while offset < data.count
            _ = try await runWindows("fileops", ["Op": .string("replace"), "Path": .string(temp), "Dest": .string(path)])
            return
        }
        try await run("umask 022; : > \(shellQuote(temp))")
        // Each chunk is one command line; Linux allows a single argument up to 128 KB, and base64 adds a third.
        let chunk = 64_000
        var offset = 0
        while offset < data.count {
            let slice = data[offset..<min(offset + chunk, data.count)]
            try await run("printf %s \(shellQuote(slice.base64EncodedString())) | \(Self.base64Decode) >> \(shellQuote(temp))")
            offset += chunk
        }
        // Keep the original's permissions.
        try await run("if [ -e \(shellQuote(path)) ]; then chmod --reference=\(shellQuote(path)) \(shellQuote(temp)) 2>/dev/null || chmod $(stat -f %Lp \(shellQuote(path)) 2>/dev/null || echo 644) \(shellQuote(temp)); fi; mv -f -- \(shellQuote(temp)) \(shellQuote(path))")
    }

    /// `base64 -d` on current systems; older macOS spells it `-D`.
    static let base64Decode = "(base64 -d 2>/dev/null || base64 -D)"

    func createFile(_ path: String) async throws {
        if os.isWindows { _ = try await runWindows("fileops", ["Op": .string("createfile"), "Path": .string(path)]); return }
        try await run("[ -e \(shellQuote(path)) ] && { echo 'Already exists' >&2; exit 1; }; : > \(shellQuote(path))")
    }

    func createFolder(_ path: String) async throws {
        if os.isWindows { _ = try await runWindows("fileops", ["Op": .string("createfolder"), "Path": .string(path)]); return }
        try await run("mkdir -p -- \(shellQuote(path))")
    }

    func rename(_ path: String, to newPath: String) async throws {
        if os.isWindows { _ = try await runWindows("fileops", ["Op": .string("rename"), "Path": .string(path), "Dest": .string(newPath)]); return }
        try await run("[ -e \(shellQuote(newPath)) ] && { echo 'Something with that name already exists' >&2; exit 1; }; mv -- \(shellQuote(path)) \(shellQuote(newPath))")
    }

    func delete(_ path: String) async throws {
        if os.isWindows { _ = try await runWindows("fileops", ["Op": .string("delete"), "Path": .string(path)]); return }
        try await run("rm -rf -- \(shellQuote(path))")
    }

    /// Runs a command and throws its own error output if it fails.
    @discardableResult
    func run(_ command: String) async throws -> String {
        let result = try await exec(command)
        guard result.succeeded else {
            let text = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw HostFileError(message: text.isEmpty ? "The command failed (exit \(result.status))." : text)
        }
        return result.stdout
    }

    /// Runs a bundled PowerShell script and throws its error message if it fails.
    @discardableResult
    func runWindows(_ script: String, _ vars: [String: PS.Value] = [:]) async throws -> String {
        let result = try await powershell(script, vars: vars)
        guard result.succeeded else {
            let text = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw HostFileError(message: text.isEmpty ? "The command failed (exit \(result.status))." : text)
        }
        return result.stdout
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

/// Icons and kinds for files, by name.
enum FileKind {
    static func symbol(for name: String, isDirectory: Bool) -> String {
        if isDirectory { return "folder.fill" }
        switch (name as NSString).pathExtension.lowercased() {
        case "swift": return "swift"
        case "js", "jsx", "ts", "tsx", "mjs", "cjs", "py", "go", "rs", "java", "kt", "c", "h", "cpp", "hpp", "cc", "m", "rb", "php", "cs", "lua": return "chevron.left.forwardslash.chevron.right"
        case "json", "yml", "yaml", "toml", "xml", "plist", "ini", "env": return "curlybraces"
        case "md", "txt", "rst", "log": return "doc.text"
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "svg", "ico": return "photo"
        case "sh", "zsh", "bash", "fish": return "terminal"
        case "zip", "gz", "tar", "tgz", "bz2", "xz", "7z": return "archivebox"
        case "pdf": return "doc.richtext"
        case "lock": return "lock"
        default: return "doc"
        }
    }

    static func isImage(_ name: String) -> Bool {
        ["png", "jpg", "jpeg", "gif", "webp", "heic", "ico"].contains((name as NSString).pathExtension.lowercased())
    }
}
