import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import Citadel

/// A SOCKS5 proxy on the phone's loopback for the in-app browser, like `ssh -D`. The browser loads addresses as
/// they are (so host names, cookies, redirects and certificates all work), and each connection is routed here:
/// the host's own addresses (localhost, plain names, private networks) go through the SSH connection, public sites
/// straight from the phone.
final class SocksProxy: @unchecked Sendable {
    let port: Int
    /// The SSH connection it was started on; a reconnect needs a new proxy (channels can't span event loops).
    let clientID: ObjectIdentifier
    private let listener: Channel

    private init(port: Int, clientID: ObjectIdentifier, listener: Channel) {
        self.port = port
        self.clientID = clientID
        self.listener = listener
    }

    static func start(on session: SSHSession, client: SSHClient) async throws -> SocksProxy {
        let bootstrap = ServerBootstrap(group: client.eventLoop)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [weak session] child in
                child.pipeline.addHandler(SocksHandler(session: session, client: client))
            }
        let listener = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        return SocksProxy(port: listener.localAddress?.port ?? 0, clientID: ObjectIdentifier(client), listener: listener)
    }

    func stop() { listener.close(promise: nil) }

    /// "Open everything through the host" in the browser's menu: for sites only the host's network can see.
    static var everythingViaHost: Bool {
        get { UserDefaults.standard.bool(forKey: "browser.allViaHost") }
        set { UserDefaults.standard.set(newValue, forKey: "browser.allViaHost") }
    }
}

extension SSHSession {
    /// The browser's proxy for this connection, started on first use and again after a reconnect.
    func browserProxyPort() async throws -> Int {
        guard let client = currentClient else { throw SessionError(message: "Not connected") }
        if let proxy = browserProxy, proxy.clientID == ObjectIdentifier(client) { return proxy.port }
        browserProxy?.stop()
        let proxy = try await SocksProxy.start(on: self, client: client)
        browserProxy = proxy
        return proxy.port
    }
}

/// One browser connection: reads the SOCKS5 greeting and CONNECT request, opens the way to the destination, then
/// gets out of the way and leaves the bytes to a pair of glue handlers.
final class SocksHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private enum Stage { case greeting, request, connecting }
    private var stage = Stage.greeting
    private var buffer = ByteBuffer()
    private weak var session: SSHSession?
    private let client: SSHClient

    init(session: SSHSession?, client: SSHClient) {
        self.session = session
        self.client = client
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = unwrapInboundIn(data)
        buffer.writeBuffer(&incoming)
        process(context: context)
    }

    private func process(context: ChannelHandlerContext) {
        switch stage {
        case .greeting:
            // VER NMETHODS METHODS…; we only offer "no authentication" (the proxy is loopback-only).
            guard buffer.readableBytes >= 2, let bytes = buffer.getBytes(at: buffer.readerIndex, length: 2) else { return }
            guard bytes[0] == 5 else { context.close(promise: nil); return }
            let length = 2 + Int(bytes[1])
            guard buffer.readableBytes >= length else { return }
            buffer.moveReaderIndex(forwardBy: length)
            context.writeAndFlush(wrapOutboundOut(context.channel.allocator.buffer(bytes: [5, 0])), promise: nil)
            stage = .request
            process(context: context)
        case .request:
            guard let (host, port, length) = Self.parseRequest(buffer) else { return }
            guard let command = buffer.getInteger(at: buffer.readerIndex + 1, as: UInt8.self), command == 1 else {
                reply(context: context, code: 7); context.close(promise: nil); return   // only CONNECT
            }
            buffer.moveReaderIndex(forwardBy: length)
            stage = .connecting
            connect(context: context, host: host, port: port)
        case .connecting:
            break   // data arriving before the reply stays in the buffer and is passed on afterwards
        }
    }

    /// Host, port and the request's length, once the whole request has arrived. Nil while incomplete.
    static func parseRequest(_ buffer: ByteBuffer) -> (host: String, port: Int, length: Int)? {
        let start = buffer.readerIndex
        guard buffer.readableBytes >= 5, let type = buffer.getInteger(at: start + 3, as: UInt8.self) else { return nil }
        var host: String
        var cursor = start + 4
        switch type {
        case 1:
            guard let bytes = buffer.getBytes(at: cursor, length: 4) else { return nil }
            host = bytes.map(String.init).joined(separator: ".")
            cursor += 4
        case 3:
            guard let count = buffer.getInteger(at: cursor, as: UInt8.self), let name = buffer.getString(at: cursor + 1, length: Int(count)) else { return nil }
            host = name
            cursor += 1 + Int(count)
        case 4:
            guard let bytes = buffer.getBytes(at: cursor, length: 16) else { return nil }
            // The standard short form ("::1"), which is what the routing rules know.
            var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, bytes, &text, socklen_t(text.count)) != nil else { return nil }
            host = String(cString: text)
            cursor += 16
        default:
            return nil
        }
        guard let port = buffer.getInteger(at: cursor, as: UInt16.self) else { return nil }
        return (host, Int(port), cursor + 2 - start)
    }

    private func connect(context: ChannelHandlerContext, host: String, port: Int) {
        let child = context.channel
        let (local, remote) = GlueHandler.matchedPair()
        let viaHost = SocksProxy.everythingViaHost || BrowserTarget.isHostSide(host)
        let ready: EventLoopFuture<Void>
        if viaHost {
            let promise = child.eventLoop.makePromise(of: Void.self)
            let client = client
            Task {
                do {
                    let origin = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
                    _ = try await client.createDirectTCPIPChannel(
                        using: SSHChannelType.DirectTCPIP(targetHost: host, targetPort: port, originatorAddress: origin)
                    ) { channel in channel.pipeline.addHandler(remote) }
                    promise.succeed(())
                } catch {
                    promise.fail(error)
                }
            }
            ready = promise.futureResult
        } else {
            ready = ClientBootstrap(group: child.eventLoop)
                .channelInitializer { channel in channel.pipeline.addHandler(remote) }
                .connect(host: host, port: port)
                .map { _ in }
        }
        ready.hop(to: child.eventLoop).whenComplete { [self] result in
            switch result {
            case .success:
                #if DEBUG
                print("[proxy] \(viaHost ? "via host" : "direct") \(host):\(port)")
                #endif
                reply(context: context, code: 0)
                let leftover = buffer
                _ = context.pipeline.removeHandler(self).flatMap { child.pipeline.addHandler(local) }.map {
                    if leftover.readableBytes > 0 { child.pipeline.fireChannelRead(NIOAny(leftover)) }
                }
            case .failure(let error):
                print("[proxy] \(viaHost ? "via host" : "direct") \(host):\(port) failed: \(error)")
                reply(context: context, code: viaHost ? 5 : 4)   // connection refused / host unreachable
                context.close(promise: nil)
            }
        }
    }

    private func reply(context: ChannelHandlerContext, code: UInt8) {
        context.writeAndFlush(wrapOutboundOut(context.channel.allocator.buffer(bytes: [5, code, 0, 1, 0, 0, 0, 0, 0, 0])), promise: nil)
    }
}
