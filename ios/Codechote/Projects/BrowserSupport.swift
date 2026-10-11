import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import Citadel

/// Opening addresses as the host sees them: dev servers on `localhost:3000`, internal services and so on.
extension SSHSession {

    /// A local port on this phone that leads to `host:port` on the host's side. Dev servers often call their own
    /// address (`http://localhost:4000/api`), so for loopback targets the same port number is used locally when it is free.
    func forwardPort(host: String, port: Int) async throws -> Int {
        let key = "\(host):\(port)"
        if let existing = forwards[key], existing.channel.isActive { return existing.localPort }
        guard let client = currentClient else { throw SessionError(message: "Not connected") }
        // Accepted sockets live on the SSH client's event loop, as in the main tunnel.
        let bootstrap = ServerBootstrap(group: client.eventLoop)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.autoRead, value: false)
            .childChannelInitializer { [weak self] child in
                let (local, remote) = GlueHandler.matchedPair()
                return child.pipeline.addHandler(local).map {
                    Task { await self?.openForward(for: child, remote: remote, host: host, port: port) }
                }
            }
        let channel: Channel
        if BrowserTarget.isLoopback(host), let same = try? await bootstrap.bind(host: "127.0.0.1", port: port).get() {
            channel = same
        } else {
            channel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        }
        let local = channel.localAddress?.port ?? 0
        forwards[key] = (channel, local)
        return local
    }

    private func openForward(for child: Channel, remote: GlueHandler, host: String, port: Int) async {
        guard let client = currentClient else { child.close(promise: nil); return }
        do {
            let origin = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
            _ = try await client.createDirectTCPIPChannel(
                using: SSHChannelType.DirectTCPIP(targetHost: host, targetPort: port, originatorAddress: origin)
            ) { channel in channel.pipeline.addHandler(remote) }
            child.setOption(ChannelOptions.autoRead, value: true).whenComplete { _ in child.read() }
        } catch {
            print("[forward] \(host):\(port) failed: \(error)")
            child.close(promise: nil)
        }
    }

    /// Whether anything answers at `host:port` on the host's side: opens a tunnel there and closes it again.
    func canReach(host: String, port: Int) async -> Bool {
        guard let client = currentClient else { return false }
        do {
            let origin = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
            let channel = try await client.createDirectTCPIPChannel(
                using: SSHChannelType.DirectTCPIP(targetHost: host, targetPort: port, originatorAddress: origin)
            ) { channel in channel.eventLoop.makeSucceededFuture(()) }
            try? await channel.close()
            return true
        } catch {
            return false
        }
    }

    /// TCP ports something is listening on at the host, for the browser's suggestions.
    func listeningPorts() async -> [Int] {
        let command = os.isWindows ? "netstat -an" : "(ss -ltnH 2>/dev/null || lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null || netstat -an 2>/dev/null)"
        guard let result = try? await exec(command), result.succeeded || !result.stdout.isEmpty else { return [] }
        return BrowserTarget.listeningPorts(in: result.stdout, excluding: [remotePort])
    }
}

/// What a typed address means: through the host, or straight from the phone.
struct BrowserTarget: Equatable {
    var scheme: String
    var host: String
    var port: Int?
    var path: String   // with query and fragment

    static func isLoopback(_ host: String) -> Bool { ["localhost", "127.0.0.1", "::1", "[::1]", "0.0.0.0"].contains(host.lowercased()) }

    /// Addresses only the host can reach, so the browser goes through it: the host itself, plain names
    /// ("intranet"), names like .local and .internal, Tailscale names, and private networks. Everything else is a
    /// public site, which the phone opens itself.
    nonisolated static func isHostSide(_ host: String) -> Bool {
        let name = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if isLoopback(name) || name.hasPrefix("127.") || (!name.contains(".") && !name.contains(":")) { return true }
        for suffix in [".local", ".localhost", ".lan", ".internal", ".intranet", ".corp", ".home.arpa", ".test", ".ts.net"] where name.hasSuffix(suffix) { return true }
        let octets = name.split(separator: ".").compactMap { Int($0) }
        if octets.count == 4, name.split(separator: ".").count == 4 {
            switch (octets[0], octets[1]) {
            case (10, _), (192, 168), (169, 254): return true
            case (172, 16...31): return true
            case (100, 64...127): return true   // carrier-grade NAT, which Tailscale uses
            default: return false
            }
        }
        if name.contains(":") { return name == "::1" || name.hasPrefix("fc") || name.hasPrefix("fd") || name.hasPrefix("fe80") }
        return false
    }

    static func parse(_ input: String) -> BrowserTarget? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(" ") else { return nil }
        let typedScheme = text.contains("://")
        if !typedScheme { text = "http://" + text }
        guard let parts = URLComponents(string: text), let host = parts.host, !host.isEmpty,
              var scheme = parts.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        // A bare public name ("youtube.com") means the https site; the host's own addresses stay http.
        if !typedScheme && !isHostSide(host) { scheme = "https" }
        var path = parts.percentEncodedPath
        if let query = parts.percentEncodedQuery { path += "?" + query }
        if let fragment = parts.percentEncodedFragment { path += "#" + fragment }
        return BrowserTarget(scheme: scheme, host: host, port: parts.port, path: path.isEmpty ? "/" : path)
    }

    /// Reached through the host rather than from the phone.
    var viaHost: Bool { Self.isHostSide(host) }

    /// The address to load.
    var url: URL? { URL(string: "\(scheme)://\(host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host)\(port.map { ":\($0)" } ?? "")\(path)") }

    var effectivePort: Int { port ?? (scheme == "https" ? 443 : 80) }

    /// The address as typed, normalised.
    var displayString: String {
        let portPart = port.map { ":\($0)" } ?? ""
        let shownScheme = scheme == "http" ? "" : "https://"
        return shownScheme + host + portPart + (path == "/" ? "" : path)
    }

    nonisolated static func listeningPorts(in output: String, excluding: [Int] = []) -> [Int] {
        var ports = Set<Int>()
        for line in output.split(whereSeparator: \.isNewline) where line.contains("LISTEN") {
            for token in line.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
                guard let match = token.range(of: #"[:.](\d{2,5})$"#, options: .regularExpression),
                      let port = Int(token[match].dropFirst()) else { continue }
                ports.insert(port)
                break
            }
        }
        // Dev servers sit below the range operating systems hand out for temporary connections.
        return ports.filter { ($0 >= 1024 && $0 < 32768 || $0 == 80 || $0 == 443) && !excluding.contains($0) }.sorted()
    }
}
