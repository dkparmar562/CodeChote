import CryptoKit
import Foundation

enum HostOS: String, Codable {
    case linux, macos, windows
    var isWindows: Bool { self == .windows }
    var displayName: String {
        switch self {
        case .linux: "Linux"
        case .macos: "macOS"
        case .windows: "Windows"
        }
    }
}

// MARK: - PowerShell

/// Everything needed to run PowerShell on a Windows host reached over OpenSSH.
///
/// Windows' default SSH shell is cmd.exe (or PowerShell), neither of which has `ls`, `git`'s usual quoting,
/// `base64` or `sh`. So Windows operations are PowerShell scripts, kept as plain `.ps1` files in the app
/// bundle (and testable with `pwsh`). Variables are passed as assignments at the top of the script, so there
/// is never any string-escaping of user text into a command line.
enum PS {
    enum Value {
        case string(String)
        case array([String])
    }

    static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "''") + "'" }

    static func loadScript(_ name: String) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: "ps1", subdirectory: "WindowsScripts")
                ?? Bundle.main.url(forResource: name, withExtension: "ps1"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "throw 'Missing script \(name)'" }
        return text
    }

    /// Wraps a script body: stop on errors, UTF-8 output, variables, and clean error messages on stderr.
    static func compose(_ body: String, vars: [String: Value] = [:], selfDelete: Bool = false) -> String {
        var lines = [
            "$ErrorActionPreference = 'Stop'",
            "$ProgressPreference = 'SilentlyContinue'",
            "[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)",
            "$OutputEncoding = New-Object Text.UTF8Encoding($false)",
        ]
        for (name, value) in vars.sorted(by: { $0.key < $1.key }) {
            switch value {
            case .string(let s): lines.append("$\(name) = \(quote(s))")
            case .array(let items): lines.append("$\(name) = @(" + items.map(quote).joined(separator: ", ") + ")")
            }
        }
        let cleanup = selfDelete ? "finally { Remove-Item -LiteralPath $PSCommandPath -Force -ErrorAction SilentlyContinue }" : ""
        lines.append("try {\n\(body)\n} catch {\n  [Console]::Error.WriteLine($_.Exception.Message)\n  exit 1\n} \(cleanup)")
        return lines.joined(separator: "\n")
    }

    static let prefix = "powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass"

    /// `-EncodedCommand` takes base64 of UTF-16, which avoids every quoting rule of cmd.exe and PowerShell.
    static func encodedCommand(_ script: String) -> String {
        "\(prefix) -EncodedCommand " + Data(script.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }).base64EncodedString()
    }
}

extension SSHSession {

    /// Works out what the host is. Windows' SSH shells can't run `uname`.
    func detectOS() async -> HostOS {
        if let result = try? await exec("uname -s"), result.succeeded {
            let name = result.stdout.lowercased()
            if name.contains("darwin") { return .macos }
            if name.contains("mingw") || name.contains("msys") || name.contains("cygwin") || name.contains("windows") { return .windows }
            return .linux
        }
        return .windows
    }

    /// Runs one of the bundled PowerShell scripts and returns its result, with Windows line endings removed.
    func powershell(_ script: String, vars: [String: PS.Value] = [:]) async throws -> CommandResult {
        let command = try await windowsCommand(for: PS.loadScript(script), vars: vars)
        var result = try await exec(command)
        result.stdout = result.stdout.replacingOccurrences(of: "\r\n", with: "\n")
        result.stderr = result.stderr.replacingOccurrences(of: "\r\n", with: "\n")
        return result
    }

    /// A command line that runs the script. cmd.exe limits a command line to about 8,000 characters, so
    /// long scripts are uploaded to a temporary file (UTF-8 with a BOM, which Windows PowerShell needs to
    /// read non-ASCII text correctly) that deletes itself when it finishes.
    func windowsCommand(for body: String, vars: [String: PS.Value]) async throws -> String {
        let inline = PS.encodedCommand(PS.compose(body, vars: vars))
        if inline.count <= 6500 { return inline }

        let name = "codechote-" + UUID().uuidString.prefix(12).lowercased() + ".ps1"
        let script = PS.compose(body, vars: vars, selfDelete: true)
        var bytes = Data([0xEF, 0xBB, 0xBF]); bytes.append(Data(script.utf8))
        var offset = 0, first = true
        while offset < bytes.count {
            let chunk = bytes[offset..<min(offset + 1200, bytes.count)]
            let mode = first ? "Create" : "Append"
            let write = "$p = Join-Path $env:TEMP \(PS.quote(name)); $b = [Convert]::FromBase64String(\(PS.quote(chunk.base64EncodedString()))); $fs = [IO.File]::Open($p, '\(mode)', 'Write', 'Read'); $fs.Write($b, 0, $b.Length); $fs.Dispose()"
            let result = try await exec(PS.encodedCommand(write))
            guard result.succeeded else { throw SessionError(message: "Couldn't upload a script to the Windows host: \(result.stderr)") }
            offset += 1200; first = false
        }
        return "\(PS.prefix) -Command \"& (Join-Path $env:TEMP '\(name)')\""
    }
}

// MARK: - Paths

/// The app keeps every path in forward-slash form (`C:/Users/me`, `/home/me`). PowerShell and git accept that
/// on Windows, and it keeps the rest of the code identical on every host. Only the edges convert.
enum HostPath {

    /// Asks the Windows host for its drives instead of a folder.
    static let drives = "@drives"

    static func join(_ base: String, _ name: String, windows: Bool) -> String {
        if windows, base.isEmpty || base == HostPath.drives { return name.hasSuffix(":") ? name + "/" : name }   // from the drive list
        if base == "/" { return "/\(name)" }
        return base.hasSuffix("/") ? base + name : "\(base)/\(name)"
    }

    /// The folder above. On Windows the parent of a drive root is the drive list (`""`).
    static func parent(_ path: String, windows: Bool) -> String {
        if windows {
            if path.isEmpty || path == drives || isDriveRoot(path) { return drives }
            let up = (path as NSString).deletingLastPathComponent
            return isDriveName(up) ? up + "/" : up
        }
        let up = (path as NSString).deletingLastPathComponent
        return up.isEmpty ? "/" : up
    }

    static func lastComponent(_ path: String) -> String {
        if isDriveRoot(path) { return String(path.prefix(2)) }
        return (path as NSString).lastPathComponent
    }

    /// `C:/Users/me` as a VS Code remote path: `/c:/Users/me`.
    static func toWorkbench(_ path: String, windows: Bool) -> String {
        guard windows, path.count >= 2, isDriveName(String(path.prefix(2))) else { return path }
        return "/" + path.prefix(1).lowercased() + path.dropFirst()
    }

    /// `/c:/Users/me` from VS Code back to `C:/Users/me`.
    static func fromWorkbench(_ path: String, windows: Bool) -> String {
        guard windows, path.hasPrefix("/"), path.count >= 3, isDriveName(String(path.dropFirst().prefix(2))) else { return path }
        let rest = String(path.dropFirst())
        return rest.prefix(1).uppercased() + rest.dropFirst()
    }

    private static func isDriveName(_ text: String) -> Bool {
        text.count == 2 && text.last == ":" && (text.first?.isLetter ?? false)
    }

    private static func isDriveRoot(_ text: String) -> Bool {
        text.count <= 3 && text.count >= 2 && isDriveName(String(text.prefix(2))) && (text.count == 2 || text.hasSuffix("/"))
    }
}
