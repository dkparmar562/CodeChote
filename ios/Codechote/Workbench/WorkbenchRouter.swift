import Foundation
import NIOCore
import NIOPosix

/// Single-origin front door for the workbench running inside the app.
///
/// The UI files ship inside the app and are served here; everything else (WebSockets,
/// `vscode-remote-resource`, ...) is forwarded to the VS Code server on the host through an SSH
/// channel. Keeping both on one origin sidesteps the server's CORS rules, which only allow
/// Microsoft's own webview origins. Every connection carries exactly one request (responses are
/// `Connection: close`), so routing can be decided from the first request head.
final class WorkbenchRouter: @unchecked Sendable {
    struct Config {
        var token: String
        var commit: String
        var quality: String
        /// The host server's own product.json: it carries the license text the client needs to
        /// unlock the server's signing module, plus gallery and webview endpoints.
        var product: [String: Any] = [:]
        var bundleRoot: URL
    }

    typealias Connector = @Sendable (GlueHandler) async throws -> Channel

    let config: Config
    let connector: Connector
    private var listener: Channel?
    private(set) var port = 0

    init(config: Config, connector: @escaping Connector) {
        self.config = config
        self.connector = connector
    }

    func start(on loop: EventLoop, preferredPort: Int = 0) async throws {
        try? await stop()
        let bootstrap = ServerBootstrap(group: loop)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [unowned self] child in
                child.pipeline.addHandler(RouterHandler(router: self))
            }
        let ch = try await bootstrap.bind(host: "127.0.0.1", port: preferredPort).get()
        listener = ch
        port = ch.localAddress?.port ?? 0
    }

    func stop() async throws {
        if let l = listener {
            listener = nil
            try await l.close()
        }
    }

    // `localhost`, not an IP: app-bound domains (needed for service workers) must be hostnames.
    var url: URL { URL(string: "http://localhost:\(port)/")! }

    // MARK: Page

    func renderWorkbenchHTML() -> String? {
        let templateURL = config.bundleRoot.appendingPathComponent("out/vs/code/browser/workbench/workbench.html")
        guard var html = try? String(contentsOf: templateURL, encoding: .utf8) else { return nil }

        var configurationDefaults: [String: Any] = [:]
        var product: [String: Any] = config.product
        product["embedderIdentifier"] = "ios-app"
        // Microsoft's CDN-hosted web worker host can't import scripts from our local origin; with
        // this unset the client runs it in a same-origin iframe served from the bundle instead.
        product.removeValue(forKey: "webEndpointUrlTemplate")

        // Phone-friendly defaults. The user's own settings still win.
        let mono = "Menlo, ui-monospace, SFMono-Regular, monospace"
        var defaults = product["configurationDefaults"] as? [String: Any] ?? [:]
        defaults.merge([
            "editor.fontFamily": mono,
            "terminal.integrated.fontFamily": mono,
            "terminal.integrated.fontSize": 12,
            "terminal.integrated.tabs.enabled": false,
            "workbench.layoutControl.enabled": false,
            "workbench.startupEditor": "none",
            "diffEditor.renderSideBySide": false,
            "editor.minimap.enabled": false,
            "editor.wordWrap": "on",
            // Your own machine: don't put opened folders in Restricted Mode, which would stop
            // extensions (and the AI agents) from running.
            "security.workspace.trust.enabled": false,
        ]) { _, ours in ours }
        product["configurationDefaults"] = defaults
        configurationDefaults = defaults
        if config.commit != "none" { product["commit"] = config.commit }
        if config.quality != "none" { product["quality"] = config.quality }
        let settings: [String: Any] = [
            "remoteAuthority": "localhost:\(port)",
            "serverBasePath": "/",
            "connectionToken": config.token,
            "_wrapWebWorkerExtHostInIframe": true,
            "enableWorkspaceTrust": false,
            "productConfiguration": product,
            "configurationDefaults": configurationDefaults,
            "callbackRoute": "/callback",
        ]
        let json = (try? JSONSerialization.data(withJSONObject: settings)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let values: [String: String] = [
            "WORKBENCH_WEB_CONFIGURATION": json.replacingOccurrences(of: "\"", with: "&quot;"),
            "WORKBENCH_AUTH_SESSION": "",
            "WORKBENCH_WEB_BASE_URL": "/static",
            "WORKBENCH_NLS_URL": "",
            "WORKBENCH_NLS_FALLBACK_URL": "/static/out/nls.messages.js",
            "WORKBENCH_SCRIPT_NONCE": UUID().uuidString,
        ]
        for (k, v) in values { html = html.replacingOccurrences(of: "{{\(k)}}", with: v) }
        return html
    }

    static func mimeType(for path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json", "map": return "application/json; charset=utf-8"
        case "wasm": return "application/wasm"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "ico": return "image/x-icon"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "ttf": return "font/ttf"
        case "otf": return "font/otf"
        case "txt", "md": return "text/plain; charset=utf-8"
        case "mp3": return "audio/mpeg"
        case "xml": return "application/xml"
        default: return "application/octet-stream"
        }
    }
}

private final class RouterHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer

    private unowned let router: WorkbenchRouter
    private var buffer = ByteBuffer()
    private var decided = false

    init(router: WorkbenchRouter) { self.router = router }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !decided else { return }
        var incoming = unwrapInboundIn(data)
        buffer.writeBuffer(&incoming)

        let bytes = buffer.readableBytesView
        guard let endRange = bytes.firstRange(of: [13, 10, 13, 10]) else {
            if buffer.readableBytes > 65_536 { context.close(promise: nil) }
            return
        }
        decided = true
        context.channel.setOption(ChannelOptions.autoRead, value: false).whenComplete { _ in }

        let headLength = endRange.upperBound - bytes.startIndex
        let headText = String(decoding: bytes.prefix(headLength), as: UTF8.self)
        let lines = headText.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        let requestLine = (lines.first ?? "").split(separator: " ", maxSplits: 2).map(String.init)
        guard requestLine.count >= 2 else { context.close(promise: nil); return }
        let method = requestLine[0].uppercased()
        let target = requestLine[1]
        let path = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? target

        // Microsoft's servers authenticate clients by a challenge signed with the proprietary
        // `vsda` module, which isn't part of an open-source UI. The server ships it under its own
        // static route (the stock web client loads it from there), so fetch it from the host.
        let config = router.config
        if path.hasPrefix("/static/node_modules/vsda/"), config.commit != "none", config.quality != "none" {
            var rewritten = lines
            rewritten[0] = "\(method) /\(config.quality)-\(config.commit)\(target) HTTP/1.1"
            forward(context: context, headLines: rewritten, headLength: headLength)
            return
        }

        let isLocal = (method == "GET" || method == "HEAD") && (path == "/" || path.hasPrefix("/static/"))
        if isLocal {
            serveLocal(context: context, method: method, path: path)
        } else {
            forward(context: context, headLines: lines, headLength: headLength)
        }
    }

    // MARK: Local

    private func serveLocal(context: ChannelHandlerContext, method: String, path: String) {
        var status = "200 OK"
        var contentType = "text/plain; charset=utf-8"
        var body = Data()

        if path == "/" {
            if let html = router.renderWorkbenchHTML() {
                contentType = "text/html; charset=utf-8"
                body = Data(html.utf8)
            } else {
                status = "500 Internal Server Error"
                body = Data("workbench.html missing from the app bundle".utf8)
            }
        } else {
            let relative = String(path.dropFirst("/static/".count)).removingPercentEncoding ?? ""
            let root = router.config.bundleRoot.standardizedFileURL
            let file = root.appendingPathComponent(relative).standardizedFileURL
            if relative.contains(".."), !file.path.hasPrefix(root.path) {
                status = "403 Forbidden"
            } else if let data = try? Data(contentsOf: file, options: .mappedIfSafe) {
                contentType = WorkbenchRouter.mimeType(for: file.path)
                body = data
            } else {
                status = "404 Not Found"
                body = Data("Not found".utf8)
            }
        }

        let head = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
        var out = context.channel.allocator.buffer(capacity: head.utf8.count + (method == "HEAD" ? 0 : body.count))
        out.writeString(head)
        if method != "HEAD" { out.writeBytes(body) }
        context.writeAndFlush(NIOAny(out)).whenComplete { _ in context.close(promise: nil) }
    }

    // MARK: Forward to the host

    private func forward(context: ChannelHandlerContext, headLines: [String], headLength: Int) {
        let isUpgrade = headLines.contains { $0.lowercased().hasPrefix("upgrade:") }
        var head = headLines
        // The server's static and resource routes want the connection token as a cookie, which the
        // stock page gets after its first load. Supply it on every forwarded request.
        let tokenCookie = "vscode-tkn=\(router.config.token)"
        // WebKit keeps cookies per host (not per port), so a stale token from an earlier session
        // may already be present, and the server would read that first. Replace it.
        if let i = head.firstIndex(where: { $0.lowercased().hasPrefix("cookie:") }) {
            let existing = head[i].dropFirst("cookie:".count)
                .split(separator: ";")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.hasPrefix("vscode-tkn=") && !$0.isEmpty }
            head[i] = "Cookie: " + (existing + [tokenCookie]).joined(separator: "; ")
        } else {
            head.append("Cookie: \(tokenCookie)")
        }
        if !isUpgrade {
            // One request per connection: keep the remote from holding it open for later UI requests.
            head.removeAll { $0.lowercased().hasPrefix("connection:") }
            head.append("Connection: close")
        }
        var prefix = context.channel.allocator.buffer(capacity: buffer.readableBytes + 32)
        prefix.writeString(head.joined(separator: "\r\n") + "\r\n\r\n")
        // Anything the client sent after the head (a request body) goes along unchanged.
        var rest = buffer
        rest.moveReaderIndex(forwardBy: headLength)
        prefix.writeBuffer(&rest)

        let channel = context.channel
        let router = self.router
        let (localGlue, remoteGlue) = GlueHandler.matchedPair()
        Task {
            do {
                let remote = try await router.connector(remoteGlue)
                // Attach the browser side before sending anything, so an early response has
                // somewhere to go.
                try await channel.pipeline.removeHandler(self).get()
                try await channel.pipeline.addHandler(localGlue).get()
                try await remote.writeAndFlush(prefix).get()
                try await channel.setOption(ChannelOptions.autoRead, value: true).get()
                channel.read()
            } catch {
                print("[router] forward failed: \(error)")
                channel.close(promise: nil)
            }
        }
    }
}
