import Citadel
import Foundation
import NIOCore
import NIOSSH

struct CommandResult {
    var stdout: String
    var stderr: String
    var status: Int
    var succeeded: Bool { status == 0 }
}

/// An error in words, instead of the SSH library's own names (`NIOSSHError.tcpShutdown` and the like).
func describeError(_ error: Error) -> String {
    let raw = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    let lower = raw.lowercased()
    // Refusals come wrapped in a "connection reset" error, so they are checked first.
    if lower.contains("connection refused") { return "The host refused the connection. Check that SSH is running on it." }
    if lower.contains("tcpshutdown") || lower.contains("connection reset") || lower.contains("channel closed") || lower.contains("ioonclosedchannel") || lower.contains("broken pipe") {
        return "The connection to the host dropped. It reconnects on its own; try again in a moment."
    }
    if lower.contains("timed out") || lower.contains("timeout") { return "The host didn't answer in time. Check the network." }
    if lower.contains("channelsetuprejected") { return "The host refused to open a session (it may have too many open). Try again in a moment." }
    if lower.contains("authentication") || lower.contains("allauthenticationoptionsfailed") { return "The host didn't accept the key or password." }
    return raw
}

/// Lets a fixed number of tasks through at a time; the rest wait their turn, in order.
actor AsyncGate {
    private var free: Int
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(_ count: Int) { free = count }

    func wait() async {
        if free > 0 { free -= 1; return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func signal() {
        if waiting.isEmpty { free += 1 } else { waiting.removeFirst().resume() }
    }
}

/// Single-quotes a string for a POSIX shell.
func shellQuote(_ text: String) -> String {
    "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

extension SSHSession {

    /// Runs a command and collects its output. A non-zero exit status is reported in the result,
    /// not thrown, so callers can show the command's own error message.
    func exec(_ command: String, maxBytes: Int = 16 << 20) async throws -> CommandResult {
        // SSH servers allow about ten sessions per connection (OpenSSH's MaxSessions); short commands take turns
        // so a burst (listing every agent's chats, reading usage) can't crowd out chats and terminals.
        await execGate.wait()
        defer { Task { await execGate.signal() } }
        guard let client = currentClient else { throw SessionError(message: "Not connected") }
        var stdout = Data(), stderr = Data()
        var status = 0
        do {
            let stream = try await client.executeCommandStream(command)
            for try await chunk in stream {
                switch chunk {
                case .stdout(let buffer): if stdout.count < maxBytes { stdout.append(contentsOf: buffer.readableBytesView) }
                case .stderr(let buffer): if stderr.count < maxBytes { stderr.append(contentsOf: buffer.readableBytesView) }
                }
            }
        } catch {
            guard let code = Self.exitStatus(from: error) else { throw error }
            status = code
        }
        return CommandResult(stdout: String(decoding: stdout, as: UTF8.self), stderr: String(decoding: stderr, as: UTF8.self), status: status)
    }

    /// Streams a command's standard output line by line while it runs, finishing when it exits.
    func execLines(_ command: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                guard let client = self.currentClient else {
                    continuation.finish(throwing: SessionError(message: "Not connected")); return
                }
                var pending = Data()
                do {
                    let stream = try await client.executeCommandStream(command)
                    for try await chunk in stream {
                        guard case .stdout(let buffer) = chunk else { continue }
                        pending.append(contentsOf: buffer.readableBytesView)
                        while let newline = pending.firstIndex(of: 0x0A) {
                            var line = pending[pending.startIndex..<newline]
                            if line.last == 0x0D { line = line.dropLast() }   // CRLF from Windows hosts
                            continuation.yield(String(decoding: line, as: UTF8.self))
                            pending = Data(pending[pending.index(after: newline)...])
                        }
                    }
                    if !pending.isEmpty { continuation.yield(String(decoding: pending, as: UTF8.self)) }
                    continuation.finish()
                } catch {
                    if Self.exitStatus(from: error) != nil {
                        if !pending.isEmpty { continuation.yield(String(decoding: pending, as: UTF8.self)) }
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Citadel reports a non-zero exit as an error whose description carries the status.
    static func exitStatus(from error: Error) -> Int? {
        let text = String(describing: error)
        guard text.contains("CommandFailed") else { return nil }
        let digits = text.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        return digits.last ?? 1
    }

    func openShell(cols: Int, rows: Int, bootstrap: String?) -> ShellSession {
        ShellSession(session: self, cols: cols, rows: rows, bootstrap: bootstrap)
    }
}

/// An interactive terminal on the host: a PTY running the user's login shell.
final class ShellSession: @unchecked Sendable {
    private let session: SSHSession
    private var writer: TTYStdinWriter?
    private var task: Task<Void, Never>?
    private let bootstrap: String?
    private var size: (cols: Int, rows: Int)

    /// Output from the host (already decoded from the channel). Called off the main thread.
    var onData: (@Sendable (Data) -> Void)?
    var onClose: (@Sendable (Error?) -> Void)?

    init(session: SSHSession, cols: Int, rows: Int, bootstrap: String?) {
        self.session = session
        self.size = (cols, rows)
        self.bootstrap = bootstrap
    }

    func start() {
        task = Task { [weak self] in
            guard let self, let client = self.session.currentClient else { return }
            let request = SSHChannelRequestEvent.PseudoTerminalRequest(
                wantReply: true,
                term: "xterm-256color",
                terminalCharacterWidth: self.size.cols,
                terminalRowHeight: self.size.rows,
                terminalPixelWidth: 0,
                terminalPixelHeight: 0,
                terminalModes: SSHTerminalModes([:])
            )
            do {
                try await client.withPTY(request) { output, writer in
                    self.writer = writer
                    if let bootstrap = self.bootstrap, !bootstrap.isEmpty {
                        try await writer.write(ByteBuffer(string: bootstrap + "\n"))
                    }
                    for try await chunk in output {
                        switch chunk {
                        case .stdout(let buffer), .stderr(let buffer):
                            self.onData?(Data(buffer.readableBytesView))
                        }
                    }
                }
                self.onClose?(nil)
            } catch {
                self.onClose?(error)
            }
        }
    }

    func send(_ data: Data) {
        guard let writer else { return }
        Task { try? await writer.write(ByteBuffer(bytes: data)) }
    }

    func resize(cols: Int, rows: Int) {
        size = (cols, rows)
        guard let writer else { return }
        Task { try? await writer.changeSize(cols: cols, rows: rows, pixelWidth: 0, pixelHeight: 0) }
    }

    func close() {
        task?.cancel()
        writer = nil
    }
}
