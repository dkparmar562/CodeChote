import Citadel
import Crypto
import Foundation
import NIOCore
import NIOPosix
import NIOSSH

struct SessionError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// One SSH connection to a host plus the loopback tunnel to the VS Code server running there.
final class SSHSession: @unchecked Sendable {
    let profile: ConnectionProfile
    private var client: SSHClient?
    var currentClient: SSHClient? { client }
    /// What the host runs. Decided once after connecting.
    private(set) var os: HostOS = .linux
    private var listener: Channel?
    /// Local ports that lead to a host:port, one per target, for the browser tab.
    var forwards: [String: (channel: Channel, localPort: Int)] = [:]
    /// The in-app browser's SOCKS proxy (SocksProxy.swift).
    var browserProxy: SocksProxy?
    /// Short commands run a few at a time (see `exec`).
    let execGate = AsyncGate(5)
    /// The remote screen viewers, by the VNC port they lead to.
    var screenViewers: [Int: RemoteDesktopServer] = [:]

    private(set) var localPort = 0
    private(set) var remotePort = 0
    private(set) var token = ""
    private(set) var commit = "none"
    private(set) var quality = "none"
    private(set) var product: [String: Any] = [:]
    private var router: WorkbenchRouter?

    init(profile: ConnectionProfile) { self.profile = profile }

    /// Where the web view should load. With the bundled UI the app serves the page itself (the
    /// token is injected into its configuration); otherwise the host-served UI is used.
    var workbenchURL: URL {
        if let router { return router.url }
        return URL(string: "http://127.0.0.1:\(localPort)/?tkn=\(token)")!
    }

    /// The commit the bundled UI was built from (written next to it by the sync script).
    static var uiCommit: String? {
        guard let root = bundledUIRoot,
              let text = try? String(contentsOf: root.appendingPathComponent("ui-commit.txt"), encoding: .utf8) else { return nil }
        let commit = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return commit.isEmpty ? nil : commit
    }

    static var bundledUIRoot: URL? {
        Bundle.main.url(forResource: "vscode-web", withExtension: nil)
    }

    // MARK: Connect

    private func authentication() throws -> SSHAuthenticationMethod {
        switch profile.auth {
        case .password:
            return .passwordBased(username: profile.username, password: profile.secret)
        case .privateKey:
            // The parser wants the exact armor lines: no trailing newline, spaces, or CRLF line endings
            // (all common when a key is pasted or read from a file).
            let pem = profile.secret
                .replacingOccurrences(of: "\r\n", with: "\n")
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .joined(separator: "\n")
            let passphrase = Keychain.get(profile.secretAccount + ".pass").flatMap { $0.isEmpty ? nil : Data($0.utf8) }
            var failures: [String] = []
            do { return .ed25519(username: profile.username, privateKey: try Curve25519.Signing.PrivateKey(sshEd25519: pem, decryptionKey: passphrase)) }
            catch { failures.append("ed25519: \(error)") }
            do { return .rsa(username: profile.username, privateKey: try Insecure.RSA.PrivateKey(sshRsa: pem, decryptionKey: passphrase)) }
            catch { failures.append("rsa: \(error)") }
            throw SessionError(message: "Could not read the private key (\(failures.joined(separator: "; "))). Use an OpenSSH ed25519 or RSA key, with its passphrase if it has one.")
        }
    }

    func connectSSH() async throws {
        let auth = try authentication()
        let settings = SSHClientSettings(
            host: profile.host,
            port: profile.port,
            authenticationMethod: { auth },
            hostKeyValidator: .custom(TOFUHostKeyDelegate(host: profile.host, port: profile.port))
        )
        client = try await SSHClient.connect(to: settings)
        os = await detectOS()
    }

    var isConnected: Bool { client?.isConnected ?? false }

    // MARK: Server

    /// Installs (first time) and starts the server, or reuses a live one. Returns true if the
    /// port/token differ from the previous call (a fresh server was started).
    @discardableResult
    func prepareServer(status: @escaping @Sendable (String) -> Void) async throws -> Bool {
        guard let client else { throw SessionError(message: "Not connected") }
        let command: String
        if os.isWindows {
            command = try await windowsCommand(for: PS.loadScript("bootstrap"), vars: [
                "Pin": .string(Self.uiCommit ?? ""),
                "UrlTemplate": .string(RemoteServerInstaller.downloadURL(forCommit: Self.uiCommit)),
            ])
        } else {
            command = RemoteServerInstaller.command(commit: Self.uiCommit)
        }
        let stream = try await client.executeCommandStream(command)
        var pending = ""
        var ready: (Int, String, String, String)?
        var productValue: [String: Any]?
        var error: String?
        var stderrTail = ""
        var transcript = ""
        var streamError: Error?
        do {
        for try await chunk in stream {
            switch chunk {
            case .stdout(let buf):
                let text = String(buffer: buf); transcript += text; pending += text
                while let nl = pending.firstIndex(of: "\n") {
                    let line = String(pending[..<nl]).trimmingCharacters(in: .whitespacesAndNewlines)
                    pending.removeSubrange(...nl)
                    if line.hasPrefix("CODECHOTE_STATUS ") {
                        status(String(line.dropFirst("CODECHOTE_STATUS ".count)))
                    } else if line.hasPrefix("CODECHOTE_PRODUCT ") {
                        let b64 = String(line.dropFirst("CODECHOTE_PRODUCT ".count))
                        if let data = Data(base64Encoded: b64),
                           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                            productValue = obj
                        }
                    } else if line.hasPrefix("CODECHOTE_ERR ") {
                        error = String(line.dropFirst("CODECHOTE_ERR ".count))
                    } else if line.hasPrefix("CODECHOTE_READY ") {
                        let parts = line.split(separator: " ")
                        if parts.count >= 3, let p = Int(parts[1]) {
                            ready = (p, String(parts[2]), parts.count > 3 ? String(parts[3]) : "none", parts.count > 4 ? String(parts[4]) : "none")
                        }
                    }
                }
            case .stderr(let buf):
                let text = String(buffer: buf); transcript += text; stderrTail = String(text.suffix(300))
            }
        }
        } catch { streamError = error }
        print("[codechote] remote transcript:\n\(transcript)")
        if let error { throw SessionError(message: error) }
        if ready == nil, let streamError {
            let out = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SessionError(message: "Remote setup failed (\(streamError)).\n\n\(out.isEmpty ? "No output from host." : String(out.suffix(800)))")
        }
        guard let (port, tok, commitValue, qualityValue) = ready else {
            throw SessionError(message: "Server did not report ready. \(stderrTail)")
        }
        let changed = port != remotePort || tok != token
        remotePort = port
        token = tok
        commit = commitValue
        if let productValue { product = productValue }
        quality = qualityValue
        return changed
    }

    // MARK: Tunnel

    /// Listens on 127.0.0.1 and forwards every accepted socket through an SSH direct-tcpip channel.
    /// `preferredPort` lets a reconnect rebind the same local port so the page's WebSockets recover.
    func startTunnel(preferredPort: Int = 0) async throws {
        try await stopTunnel()
        guard let client else { throw SessionError(message: "Not connected") }
        // Accepted sockets must live on the SSH client's event loop: GlueHandler touches both
        // channels from one side, which NIO only allows on the owning loop.
        let bootstrap = ServerBootstrap(group: client.eventLoop)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.autoRead, value: false)
            .childChannelInitializer { [weak self] child in
                let (local, remote) = GlueHandler.matchedPair()
                return child.pipeline.addHandler(local).map {
                    Task { await self?.openRemote(for: child, remote: remote) }
                }
            }
        let ch = try await bootstrap.bind(host: "127.0.0.1", port: preferredPort).get()
        listener = ch
        localPort = ch.localAddress?.port ?? 0
    }

    private func openRemote(for child: Channel, remote: GlueHandler) async {
        guard let client else { child.close(promise: nil); return }
        do {
            let origin = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
            _ = try await client.createDirectTCPIPChannel(
                using: SSHChannelType.DirectTCPIP(targetHost: "127.0.0.1", targetPort: remotePort, originatorAddress: origin)
            ) { channel in
                channel.pipeline.addHandler(remote)
            }
            child.setOption(ChannelOptions.autoRead, value: true).whenComplete { _ in child.read() }
        } catch {
            print("[tunnel] direct-tcpip to :\(remotePort) failed: \(error)")
            child.close(promise: nil)
        }
    }

    /// Starts the single-origin router (bundled UI + forwarding) instead of the raw tunnel.
    func startRouter(preferredPort: Int = 0) async throws {
        // The browser keys all its storage (open files, terminals, recents, settings) by origin, so
        // the local port must not change between launches. Each server gets its own stable port.
        var port = preferredPort != 0 ? preferredPort : StablePort.port(for: profile.id)
        for attempt in 0..<6 {
            do {
                try await startRouterOnce(port: port)
                return
            } catch {
                if attempt == 5 { throw error }
                port = StablePort.reroll(for: profile.id)
            }
        }
    }

    private func startRouterOnce(port preferredPort: Int) async throws {
        guard let client else { throw SessionError(message: "Not connected") }
        guard let root = Self.bundledUIRoot else { throw SessionError(message: "UI bundle missing from the app") }
        try await stopTunnel()
        let router = WorkbenchRouter(
            config: .init(token: token, commit: commit, quality: quality, product: product, bundleRoot: root),
            connector: { [weak self] glue in
                guard let self, let client = self.client else { throw SessionError(message: "Not connected") }
                let origin = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
                return try await client.createDirectTCPIPChannel(
                    using: SSHChannelType.DirectTCPIP(targetHost: "127.0.0.1", targetPort: self.remotePort, originatorAddress: origin)
                ) { channel in channel.pipeline.addHandler(glue) }
            }
        )
        try await router.start(on: client.eventLoop, preferredPort: preferredPort)
        self.router = router
        localPort = router.port
    }

    /// Bundled UI when present, otherwise the host-served UI through a raw tunnel.
    func startFrontEnd(preferredPort: Int = 0) async throws {
        if Self.bundledUIRoot != nil {
            try await startRouter(preferredPort: preferredPort)
        } else {
            try await startTunnel(preferredPort: preferredPort)
        }
    }

    func stopTunnel() async throws {
        if let r = router {
            router = nil
            try? await r.stop()
        }
        if let l = listener {
            listener = nil
            try? await l.close()
        }
    }

    // MARK: Browsing the host

    /// Lists a folder on the host. An empty path means the home folder.
    func listDirectory(_ path: String) async throws -> DirectoryListing {
        guard client != nil else { throw SessionError(message: "Not connected") }
        let output: String
        if os.isWindows {
            let result = try await powershell("list", vars: ["Path": .string(path)])
            guard result.succeeded else { throw SessionError(message: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "Couldn't open \(path.isEmpty ? "the home folder" : path).") }
            output = result.stdout
        } else {
            let quoted = shellQuote(path)
            let command = "sh -c 'cd -- \"${1:-$HOME}\" 2>&1 && pwd && ls -1Ap' sh \(quoted)"
            do { output = String(buffer: try await client!.executeCommand(command, maxResponseSize: 4 << 20)) }
            catch { throw SessionError(message: "Couldn't open \(path.isEmpty ? "the home folder" : path).") }
        }
        guard let listing = Self.parseDirectoryOutput(output) else { throw SessionError(message: "Empty listing") }
        return listing
    }

    /// First line is the resolved folder (empty for the Windows drive list), then one name per line, folders
    /// ending in `/`.
    static func parseDirectoryOutput(_ output: String) -> DirectoryListing? {
        var lines = output.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard !lines.isEmpty else { return nil }
        let resolved = lines.removeFirst().trimmingCharacters(in: .whitespaces)
        let entries = lines.filter { !$0.isEmpty }.map { line -> DirectoryEntry in
            let isDirectory = line.hasSuffix("/")
            return DirectoryEntry(name: isDirectory ? String(line.dropLast()) : line, isDirectory: isDirectory)
        }
        .sorted { ($0.isDirectory ? 0 : 1, $0.name.lowercased()) < ($1.isDirectory ? 0 : 1, $1.name.lowercased()) }
        return DirectoryListing(path: resolved, entries: entries)
    }

    // MARK: Lifecycle

    func disconnect() async {
        try? await stopTunnel()
        try? await client?.close()
        client = nil
    }

    /// Re-establishes SSH and the tunnel (same local port) after iOS suspended the app.
    /// Returns true if the server was restarted and the page must be reloaded with a new URL.
    func revive(status: @escaping @Sendable (String) -> Void) async throws -> Bool {
        if isConnected, listener != nil || router != nil { return false }
        let port = localPort
        try? await client?.close()
        try await connectSSH()
        let changed = try await prepareServer(status: status)
        try await startFrontEnd(preferredPort: port)
        return changed
    }
}

/// A fixed local port per server, so the page's origin (and with it everything the browser stores)
/// stays the same from one launch to the next.
enum StablePort {
    private static func key(_ id: UUID) -> String { "port.\(id.uuidString)" }

    static func port(for id: UUID) -> Int {
        let stored = UserDefaults.standard.integer(forKey: key(id))
        return stored != 0 ? stored : reroll(for: id)
    }

    @discardableResult
    static func reroll(for id: UUID) -> Int {
        let port = Int.random(in: 41_000...49_999)
        UserDefaults.standard.set(port, forKey: key(id))
        return port
    }
}
