import Network
import XCTest
@testable import Codechote

/// Runs the app's host code over real SSH against the local test host (`task host:start`): commands, files,
/// search, repositories, detached jobs, and a full Claude Code turn with the fake CLI.
///
/// `ios/scripts/test.sh` tells the tests where the test host is (CODECHOTE_TESTHOST). Without it, or when the host
/// isn't running, these tests are skipped, so plain unit test runs stay fast and self-contained.
@MainActor
final class HostIntegrationTests: XCTestCase {
    private static var shared: SSHSession?
    private var session: SSHSession!
    private var repo: String!

    override func setUp() async throws {
        guard let home = ProcessInfo.processInfo.environment["CODECHOTE_TESTHOST"], !home.isEmpty else {
            throw XCTSkip("No test host configured (run with task test:integration).")
        }
        repo = (home as NSString).deletingLastPathComponent + "/testrepo"
        if let existing = Self.shared, existing.isConnected { session = existing; return }
        guard let key = try? String(contentsOfFile: home + "/client_ed25519", encoding: .utf8) else {
            throw XCTSkip("The test host's key isn't there (task host:start).")
        }
        var profile = ConnectionProfile()
        profile.id = UUID(uuidString: "00000000-0000-0000-0000-00000000E2E1")!
        profile.name = "Integration host"
        profile.host = "127.0.0.1"
        profile.port = 2222
        profile.username = ProcessInfo.processInfo.environment["CODECHOTE_TESTHOST_USER"] ?? NSUserName()
        profile.auth = .privateKey
        profile.secret = key
        let session = SSHSession(profile: profile)
        do { try await session.connectSSH() } catch { throw XCTSkip("The test host isn't running (task host:start): \(error)") }
        Self.shared = session
        self.session = session
    }

    func testCommandsReportOutputAndStatus() async throws {
        let ok = try await session.exec("printf 'hello'; printf 'oops' >&2")
        let failed = try await session.exec("exit 3")
        XCTAssertEqual([ok.stdout, ok.stderr, String(ok.status), String(failed.status)], ["hello", "oops", "0", "3"])
    }

    func testFilesRoundTripThroughTheHost() async throws {
        let folder = repo + "/.integration-\(UUID().uuidString.prefix(6))"
        try await session.createFolder(folder)
        defer { Task { [session] in try? await session?.delete(folder) } }
        // Bigger than one write chunk, and binary.
        let data = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try await session.writeFile(folder + "/blob.bin", data: data)
        let (read, truncated) = try await session.readFile(folder + "/blob.bin")
        try await session.rename(folder + "/blob.bin", to: folder + "/renamed.bin")
        let listing = try await session.exec("ls \(shellQuote(folder))").stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual([read == data, truncated], [true, false])
        XCTAssertEqual(listing, "renamed.bin")
    }

    func testSearchFindsTextInTheRepository() async throws {
        let found = try await ProjectSearch.run("func greet", in: repo, matchCase: true, on: session)
        XCTAssertEqual(found.matches.map { "\($0.path):\($0.line)" }, ["greet.swift:3"])
    }

    func testRepositoriesAreFoundForTouchedFiles() async throws {
        let found = await RepoDiscovery.find(on: session, folder: repo, touched: [repo + "/greet.swift"])
        let root = try await session.exec("cd \(shellQuote(repo)) && git rev-parse --show-toplevel").stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(found, RepoDiscovery.Found(repos: [root], files: [root: ["greet.swift"]]))
    }

    func testDetachedJobOutputArrivesInOrder() async throws {
        let job = try await HostJob.start("printf 'one\\ntwo\\nthree\\n'", in: repo, input: "", streamingInput: false, on: session)
        var lines: [String] = []
        for try await line in job.lines() { lines.append(line) }
        XCTAssertEqual(lines, ["one", "two", "three"])
    }

    /// The browser's proxy: an address only the host can reach (a server on its loopback) loads through it, with its
    /// own host name, as a web view would.
    func testBrowserProxyReachesTheHostsOwnAddresses() async throws {
        let port = 18_000 + Int.random(in: 0..<1000)
        let folder = repo + "/.proxy-\(UUID().uuidString.prefix(6))"
        try await session.createFolder(folder)
        try await session.writeFile(folder + "/hello.txt", data: Data("served by the host".utf8))
        _ = try await session.exec("cd \(shellQuote(folder)) && (nohup python3 -m http.server \(port) --bind 127.0.0.1 >/dev/null 2>&1 & echo $! > server.pid)")
        defer { Task { [session] in _ = try? await session?.exec("kill $(cat \(shellQuote(folder))/server.pid); rm -rf \(shellQuote(folder))") } }
        try await Task.sleep(for: .seconds(1))

        let proxy = try await session.browserProxyPort()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.proxyConfigurations = [ProxyConfiguration(socksv5Proxy: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(integerLiteral: UInt16(proxy))))]
        let (data, response) = try await URLSession(configuration: configuration).data(from: URL(string: "http://localhost:\(port)/hello.txt")!)
        XCTAssertEqual([String(decoding: data, as: UTF8.self), String((response as? HTTPURLResponse)?.statusCode ?? 0)], ["served by the host", "200"])
    }

    /// A whole turn with the fake Claude Code: streamed reply, tool call, result, and a message sent mid-turn.
    func testClaudeTurnWithAFollowUpSentWhileItWorks() async throws {
        let adapter = ClaudeAdapter()
        guard let cli = await adapter.locateCLI(on: session) else { throw XCTSkip("The fake claude isn't on the test host.") }
        var texts: [String] = [], started = false, finished = false, followUpSent = false
        let stream = adapter.send(prompt: "hello from the tests", sessionID: nil, folder: repo, mode: .bypass, model: "", allowedTools: [], on: session, cli: cli)
        for try await event in stream {
            switch event {
            case .started: started = true
            case .job(let job) where !followUpSent:
                followUpSent = true
                try await job.appendInput(ClaudeAdapter.inputLine("and one more thing"))
            case .message(let message) where message.role == .assistant:
                texts.append(message.plainText)
            case .finished: finished = true
            default: break
            }
        }
        let replies = Set(texts)
        XCTAssertEqual([started, finished, followUpSent], [true, true, true])
        XCTAssertTrue(replies.contains { $0.contains("You said: hello from the tests") }, "\(replies)")
        XCTAssertTrue(replies.contains { $0.contains("Got your follow-up: and one more thing") }, "\(replies)")
    }
}
