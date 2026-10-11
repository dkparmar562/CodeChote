import Foundation

/// A command running on the host on its own, so it survives the phone losing the connection (sleep, a network
/// change, leaving the app). Its output goes to a log file on the host, which the app follows and picks up again
/// from where it left off after reconnecting. Optionally its input is a file the app can keep adding to, which is
/// how a message reaches Claude Code while it is still working.
///
/// Files: `~/.codechote/jobs/<id>.log` (output, ending with `@@CC_EXIT <status>`), `.in` (input), `.pid`, `.feed`.
final class HostJob: @unchecked Sendable {
    let id = UUID().uuidString.lowercased()
    let session: SSHSession
    /// The input stays open for more messages (Claude Code's stream-json input).
    let streamingInput: Bool
    private let lock = NSLock()
    private var _inputs = 1
    private var finished = false

    /// How many messages went in, the first one included.
    var inputs: Int { lock.lock(); defer { lock.unlock() }; return _inputs }

    private var base: String { "\"$HOME/.codechote/jobs/\(id)\"" }

    private init(session: SSHSession, streamingInput: Bool) {
        self.session = session
        self.streamingInput = streamingInput
    }

    static let exitMarker = "@@CC_EXIT"

    /// Starts `command` (already quoted for sh) in `folder`, reading `input` on stdin.
    static func start(_ command: String, in folder: String, input: String, streamingInput: Bool, on session: SSHSession) async throws -> HostJob {
        let job = HostJob(session: session, streamingInput: streamingInput)
        let b = job.base
        // With streaming input, a `tail -f` of the input file feeds a pipe; killing it ends the input.
        // The feed starts from a subshell so this shell doesn't report it ("Terminated") when it is stopped.
        let feed = streamingInput
            ? "mkfifo \"$0.fifo\" && ( tail -n +1 -f \"$0.in\" > \"$0.fifo\" 2>/dev/null & echo $! > \"$0.feed\" ) && { \(command); } < \"$0.fifo\" >> \"$0.log\" 2>&1"
            : "{ \(command); } < \"$0.in\" >> \"$0.log\" 2>&1"
        let inner = "\(feed); s=$?; [ -f \"$0.feed\" ] && kill $(cat \"$0.feed\") 2>/dev/null; echo \"\(exitMarker) $s\" >> \"$0.log\"; rm -f \"$0.fifo\""
        let script = """
        mkdir -p "$HOME/.codechote/jobs" && find "$HOME/.codechote/jobs" -type f -mtime +3 -delete 2>/dev/null
        printf %s \(shellQuote(Data(input.utf8).base64EncodedString())) | \(SSHSession.base64Decode) > \(b).in
        : > \(b).log
        cd \(shellQuote(folder)) || exit 1
        nohup sh -c \(shellQuote(inner)) \(b) </dev/null >/dev/null 2>&1 &
        echo $! > \(b).pid
        """
        let result = try await session.exec("sh -c \(shellQuote(script))")
        guard result.succeeded else { throw SessionError(message: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "Couldn't start it on the host") }
        return job
    }

    /// The job's output, line by line, from the start. If the connection drops it reconnects and carries on from
    /// the line it had reached; it ends when the job does.
    func lines() -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [self] in
                var seen = 0
                var failures = 0
                while !Task.isCancelled {
                    do {
                        // Follows the log until the job is gone (then a moment more for its last lines).
                        let follow = "f=\(base); tail -n +\(seen + 1) -f \"$f.log\" & t=$!; while kill -0 \"$(cat \"$f.pid\" 2>/dev/null)\" 2>/dev/null; do sleep 1; done; sleep 1; { kill $t; wait $t; } 2>/dev/null"
                        var sawExit = false
                        for try await line in session.execLines("sh -c \(shellQuote(follow))") {
                            seen += 1
                            failures = 0
                            if line.hasPrefix(Self.exitMarker) { sawExit = true; break }
                            continuation.yield(line)
                        }
                        markFinished()
                        _ = sawExit
                        continuation.finish()
                        return
                    } catch {
                        if Task.isCancelled { return }
                        failures += 1
                        guard failures <= 30 else {
                            continuation.finish(throwing: SessionError(message: "Lost the connection to the host. The agent keeps working there; open this chat again later to see its reply."))
                            return
                        }
                        print("[job] connection dropped (\(error)); reconnecting, try \(failures)")
                        try? await Task.sleep(for: .seconds(min(8, Double(failures) * 1.5)))
                        _ = try? await session.revive { _ in }
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Adds a message to the input of a streaming job.
    func appendInput(_ line: String) async throws {
        guard streamingInput else { return }
        let script = "printf '%s\\n' \(shellQuote(Data(line.utf8).base64EncodedString())) | \(SSHSession.base64Decode) >> \(base).in"
        let result = try await session.exec("sh -c \(shellQuote(script))")
        guard result.succeeded else { throw SessionError(message: "Couldn't send it to the agent") }
        lock.lock(); _inputs += 1; lock.unlock()
    }

    /// Ends the input, so the program finishes once it has answered everything.
    func closeInput() {
        guard streamingInput else { return }
        Task { _ = try? await session.exec("sh -c \(shellQuote("kill $(cat \(base).feed) 2>/dev/null"))") }
    }

    /// Stops the job and what it started.
    func stop() {
        guard !isFinished else { return }
        let script = "p=$(cat \(base).pid 2>/dev/null); [ -n \"$p\" ] && { pkill -TERM -P \"$p\" 2>/dev/null; kill -TERM \"$p\" 2>/dev/null; }; kill $(cat \(base).feed 2>/dev/null) 2>/dev/null"
        Task { _ = try? await session.exec("sh -c \(shellQuote(script))") }
    }

    private func markFinished() { lock.lock(); finished = true; lock.unlock() }
    private var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }
}
