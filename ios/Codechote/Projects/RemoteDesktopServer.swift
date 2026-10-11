import Citadel
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSH
import NIOWebSocket

/// Serves the bundled VNC viewer (noVNC) on a local port and turns its WebSocket into a plain TCP connection to the
/// host's VNC server, carried over the SSH connection. The VNC server therefore never has to be reachable from the
/// network: it can stay bound to the host's own loopback address.
final class RemoteDesktopServer: @unchecked Sendable {
    /// Opens the connection to the VNC server on the host. The returned channel's incoming bytes go to `webSocket`.
    typealias Connector = @Sendable (_ webSocket: Channel) async throws -> Channel

    private let root: URL
    private let connector: Connector
    private var listener: Channel?
    private(set) var port = 0

    init(root: URL, connector: @escaping Connector) {
        self.root = root
        self.connector = connector
    }

    func start(on loop: EventLoop) async throws {
        let upgrader = NIOWebSocketServerUpgrader(
            maxFrameSize: 1 << 22,
            shouldUpgrade: { channel, head in
                guard head.uri.hasPrefix("/websockify") else { return channel.eventLoop.makeSucceededFuture(nil) }
                // Answer with a sub-protocol only if the viewer asked for one: a browser drops a connection whose
                // server names a protocol it did not offer.
                let offered = head.headers["Sec-WebSocket-Protocol"].flatMap { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
                var headers = HTTPHeaders()
                if offered.contains("binary") { headers.add(name: "Sec-WebSocket-Protocol", value: "binary") }
                return channel.eventLoop.makeSucceededFuture(headers)
            },
            upgradePipelineHandler: { [self] channel, _ in
                channel.pipeline.removeHandler(name: "static-files").flatMap {
                    channel.pipeline.addHandler(WebSocketToTCP(server: self))
                }
            }
        )
        let bootstrap = ServerBootstrap(group: loop)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [self] channel in
                let config: NIOHTTPServerUpgradeConfiguration = (upgraders: [upgrader], completionHandler: { _ in })
                return channel.pipeline.configureHTTPServerPipeline(withServerUpgrade: config).flatMap {
                    channel.pipeline.addHandler(StaticFiles(root: root), name: "static-files")
                }
            }
        let channel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        listener = channel
        port = channel.localAddress?.port ?? 0
    }

    func stop() async {
        if let listener { try? await listener.close() }
        listener = nil
    }

    var url: URL { URL(string: "http://localhost:\(port)/rd.html")! }

    fileprivate func openRemote(for webSocket: Channel) async throws -> Channel { try await connector(webSocket) }

    // MARK: Files

    static func contentType(for path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "html": "text/html; charset=utf-8"
        case "js", "mjs": "text/javascript; charset=utf-8"
        case "css": "text/css; charset=utf-8"
        case "svg": "image/svg+xml"
        case "png": "image/png"
        case "json": "application/json"
        default: "application/octet-stream"
        }
    }

    /// The file a request path refers to, or nil if it leaves the folder.
    static func resolve(_ requestPath: String, in root: URL) -> URL? {
        var path = requestPath.split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"
        path = path.removingPercentEncoding ?? path
        if path == "/" || path.isEmpty { path = "/rd.html" }
        let parts = path.split(separator: "/").map(String.init)
        guard !parts.contains(".."), !parts.contains(".") else { return nil }
        return parts.reduce(root) { $0.appendingPathComponent($1) }
    }
}

/// Answers plain HTTP requests with files from the viewer's folder.
private final class StaticFiles: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let root: URL
    private var uri = "/"

    init(root: URL) { self.root = root }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head): uri = head.uri
        case .body: break
        case .end: respond(context: context)
        }
    }

    private func respond(context: ChannelHandlerContext) {
        var headers = HTTPHeaders()
        headers.add(name: "Connection", value: "close")
        headers.add(name: "Cache-Control", value: "no-store")
        var status = HTTPResponseStatus.ok
        var body = ByteBuffer()
        if let file = RemoteDesktopServer.resolve(uri, in: root), let data = try? Data(contentsOf: file) {
            headers.add(name: "Content-Type", value: RemoteDesktopServer.contentType(for: file.path))
            body.writeBytes(data)
        } else {
            status = .notFound
            headers.add(name: "Content-Type", value: "text/plain")
            body.writeString("Not found")
        }
        headers.add(name: "Content-Length", value: String(body.readableBytes))
        context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: status, headers: headers))), promise: nil)
        context.write(wrapOutboundOut(.body(.byteBuffer(body))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in context.close(promise: nil) }
    }
}

/// Carries the viewer's WebSocket messages to the VNC server as a byte stream, and back.
private final class WebSocketToTCP: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private let server: RemoteDesktopServer
    private var remote: Channel?
    private var waiting: [ByteBuffer] = []
    private var closed = false

    init(server: RemoteDesktopServer) { self.server = server }

    func handlerAdded(context: ChannelHandlerContext) {
        let webSocket = context.channel
        Task { [server] in
            do {
                let remote = try await server.openRemote(for: webSocket)
                webSocket.eventLoop.execute { self.attach(remote) }
            } catch {
                print("[screen] couldn't reach the VNC server: \(error)")
                webSocket.eventLoop.execute { webSocket.close(promise: nil) }
            }
        }
    }

    private func attach(_ remote: Channel) {
        if closed { remote.close(promise: nil); return }
        self.remote = remote
        for buffer in waiting { remote.writeAndFlush(buffer, promise: nil) }
        waiting.removeAll()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        switch frame.opcode {
        case .binary, .text:
            let payload = frame.unmaskedData
            if let remote { remote.writeAndFlush(payload, promise: nil) } else { waiting.append(payload) }
        case .ping:
            let pong = WebSocketFrame(fin: true, opcode: .pong, data: frame.unmaskedData)
            context.writeAndFlush(wrapOutboundOut(pong), promise: nil)
        case .connectionClose:
            context.close(promise: nil)
        default:
            break
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        closed = true
        remote?.close(promise: nil)
        remote = nil
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}

/// Sits on the SSH channel to the VNC server and wraps what comes back in WebSocket messages for the viewer.
final class TCPToWebSocket: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let webSocket: Channel

    init(webSocket: Channel) { self.webSocket = webSocket }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        webSocket.writeAndFlush(WebSocketFrame(fin: true, opcode: .binary, data: buffer), promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) { webSocket.close(promise: nil) }

    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}

// MARK: - Hooking it to the SSH connection

extension SSHSession {
    /// Starts (or reuses) the viewer for the host's VNC server on `vncPort`, and returns the page's address.
    func startScreenViewer(vncPort: Int) async throws -> URL {
        if let existing = screenViewers[vncPort] { return existing.url }
        guard let client = currentClient else { throw SessionError(message: "Not connected") }
        guard let root = Bundle.main.url(forResource: "novnc", withExtension: nil) else { throw SessionError(message: "The viewer is missing from the app") }
        let server = RemoteDesktopServer(root: root) { webSocket in
            let origin = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
            return try await client.createDirectTCPIPChannel(
                using: SSHChannelType.DirectTCPIP(targetHost: "127.0.0.1", targetPort: vncPort, originatorAddress: origin)
            ) { channel in channel.pipeline.addHandler(TCPToWebSocket(webSocket: webSocket)) }
        }
        try await server.start(on: client.eventLoop)
        screenViewers[vncPort] = server
        return server.url
    }
}
