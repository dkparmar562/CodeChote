import Observation
import SwiftUI
import Network
import WebKit

/// A browser for working on a host: the host's own addresses (`localhost:3000`, internal names, private networks)
/// open as the host sees them, through the SSH connection, and public sites open straight from the phone. The web
/// view loads every address as it is, through a SOCKS proxy in the app that routes each connection
/// (SocksProxy.swift), so host names, cookies, redirects and https all behave as in any browser.
@MainActor
@Observable
final class BrowserModel: NSObject, WKNavigationDelegate, WKUIDelegate {
    var address = ""
    var title = ""
    var canGoBack = false
    var canGoForward = false
    var isLoading = false
    var errorText: String?
    var hasPage = false
    var onPageChange: ((String, String) -> Void)?

    let webView: WKWebView
    /// The host's connection, asked for each time: it changes when the host reconnects.
    private let session: () -> SSHSession?
    private let store: WKWebsiteDataStore
    private var proxyPort: Int?
    private var observers: [NSKeyValueObservation] = []

    init(session: @escaping () -> SSHSession?) {
        self.session = session
        // Each host keeps its own cookies and storage, like a browser profile.
        store = WKWebsiteDataStore(forIdentifier: session()?.profile.id ?? UUID())
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.isInspectable = true
        observers = [
            webView.observe(\.canGoBack) { [weak self] web, _ in Task { @MainActor in self?.canGoBack = web.canGoBack } },
            webView.observe(\.canGoForward) { [weak self] web, _ in Task { @MainActor in self?.canGoForward = web.canGoForward } },
            webView.observe(\.isLoading) { [weak self] web, _ in Task { @MainActor in self?.isLoading = web.isLoading } },
            webView.observe(\.title) { [weak self] web, _ in Task { @MainActor in self?.title = web.title ?? "" } },
            webView.observe(\.url) { [weak self] web, _ in Task { @MainActor in self?.syncAddress(web.url) } },
        ]
    }

    /// Opens what was typed: an address, or a web search for anything that isn't one.
    func open(_ input: String) {
        errorText = nil
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard let target = BrowserTarget.parse(text), let url = target.url else {
            var search = URLComponents(string: "https://www.google.com/search")!
            search.queryItems = [URLQueryItem(name: "q", value: text)]
            if let url = search.url { load(url, target: nil) }
            return
        }
        load(url, target: target)
    }

    private func load(_ url: URL, target: BrowserTarget?) {
        address = target?.displayString ?? url.absoluteString
        Task {
            let host = session()
            if let target, target.viaHost || SocksProxy.everythingViaHost {
                guard let host else { errorText = "Not connected to the host. It reconnects on its own; try again in a moment."; return }
                // Say plainly when nothing is running there, instead of a blank page and a vague network error.
                guard await host.canReach(host: target.host, port: target.effectivePort) else {
                    errorText = "Nothing is answering at \(target.host):\(target.effectivePort) on the host. Start the server there (or ask the agent to), then reload."
                    return
                }
            }
            await useProxy(of: host)
            hasPage = true
            webView.load(URLRequest(url: url))
        }
    }

    /// Points the web view at this connection's proxy (a new one after a reconnect). Without a connection, public
    /// sites still open directly.
    private func useProxy(of host: SSHSession?) async {
        let port = try? await host?.browserProxyPort()
        guard port != proxyPort else { return }
        proxyPort = port
        store.proxyConfigurations = port.map { [ProxyConfiguration(socksv5Proxy: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(integerLiteral: UInt16($0))))] } ?? []
    }

    private func syncAddress(_ url: URL?) {
        guard let url else { return }
        address = BrowserTarget.parse(url.absoluteString)?.displayString ?? url.absoluteString
        onPageChange?(address, title)
    }

    // MARK: Navigation

    /// The host's dev servers use self-signed certificates; the connection to them runs inside the SSH tunnel, so
    /// for the host's own addresses (and only those) the certificate is accepted.
    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping @MainActor (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust, BrowserTarget.isHostSide(space.host),
              let trust = space.serverTrust else { completionHandler(.performDefaultHandling, nil); return }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        errorText = "Couldn't load the page: \(error.localizedDescription)"
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { open(url.absoluteString) }   // new-window links open in this one
        return nil
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reload() {
        if errorText != nil, !address.isEmpty { open(address) } else { webView.reload() }
    }

    /// Clears cookies, storage and caches of every site opened in this browser.
    func clearWebsiteData() async {
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        webView.reload()
    }
}

/// The address bar, the page, and a start page with what's running on the host.
struct BrowserView: View {
    let browser: BrowserModel
    let session: () -> SSHSession?
    /// Shown first when there is no page yet.
    var focusWhenEmpty = true

    @State private var input = ""
    @State private var ports: [Int] = []
    @FocusState private var typing: Bool
    private static let recentsKey = "browser.recents"

    var body: some View {
        VStack(spacing: 0) {
            bar
            ZStack {
                if browser.hasPage {
                    WebHost(web: browser.webView)
                } else {
                    start
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(.systemBackground))
        .onChange(of: browser.address) { _, address in if !typing { input = address } }
        .task {
            input = browser.address
            // Only when nothing is being opened (an address loads in the background first).
            if !browser.hasPage && browser.address.isEmpty && focusWhenEmpty { typing = true }
            ports = await session()?.listeningPorts() ?? []
        }
    }

    private var bar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Button { browser.goBack() } label: { Image(systemName: "chevron.backward") }
                    .disabled(!browser.canGoBack).frame(width: 30)
                    .accessibilityLabel("Back")
                Button { browser.goForward() } label: { Image(systemName: "chevron.forward") }
                    .disabled(!browser.canGoForward).frame(width: 30)
                    .accessibilityLabel("Forward")
                HStack(spacing: 6) {
                    Image(systemName: "network").foregroundStyle(.secondary).font(.system(size: 13))
                    TextField("localhost:3000", text: $input)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        .submitLabel(.go).focused($typing)
                        .onSubmit { go(input) }
                    if browser.isLoading { ProgressView().controlSize(.small) }
                    else if !input.isEmpty && typing { Button { input = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) } }
                }
                .padding(.horizontal, 12).frame(height: 38)
                .background(Color.secondary.opacity(0.14), in: Capsule())
                Menu {
                    Button("Reload", systemImage: "arrow.clockwise") { browser.reload() }.disabled(!browser.hasPage)
                    Button("Copy Address", systemImage: "doc.on.doc") { UIPasteboard.general.string = browser.address }
                        .disabled(browser.address.isEmpty)
                    if let target = BrowserTarget.parse(browser.address), !target.viaHost, let url = target.url {
                        Button("Open in Safari", systemImage: "safari") { UIApplication.shared.open(url) }
                    }
                    Toggle("Open Everything Through the Host", systemImage: "server.rack", isOn: Binding(
                        get: { SocksProxy.everythingViaHost }, set: { SocksProxy.everythingViaHost = $0; browser.reload() }))
                    Button("Clear Website Data", systemImage: "trash", role: .destructive) { Task { await browser.clearWebsiteData() } }
                } label: { Image(systemName: "ellipsis.circle") }
                .frame(width: 30)
                .accessibilityLabel("More")
            }
            .font(.system(size: 16, weight: .medium))
            if let error = browser.errorText {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.bar)
    }

    private var start: some View {
        List {
            Section {
                Text("Addresses open from the host's side, so localhost:3000 is a server running there.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if !ports.isEmpty {
                Section("Running on This Host") {
                    ForEach(ports, id: \.self) { port in
                        Button { go("localhost:\(port)") } label: { Label("localhost:" + String(port), systemImage: "bolt.horizontal") }
                    }
                }
            }
            let recents = UserDefaults.standard.stringArray(forKey: Self.recentsKey) ?? []
            if !recents.isEmpty {
                Section("Recent") {
                    ForEach(recents, id: \.self) { recent in Button(recent) { go(recent) } }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { ports = await session()?.listeningPorts() ?? [] }
    }

    private func go(_ text: String) {
        typing = false
        input = text
        browser.open(text)
        var recents = UserDefaults.standard.stringArray(forKey: Self.recentsKey) ?? []
        recents.removeAll { $0 == text }
        recents.insert(text, at: 0)
        UserDefaults.standard.set(Array(recents.prefix(8)), forKey: Self.recentsKey)
    }
}

/// A project's browser tab. It reopens where it was.
struct BrowserTab: View {
    @Environment(AppModel.self) private var model
    let tab: AppTab
    let tabs: TabsModel
    let isSelected: Bool

    @State private var browser: BrowserModel?

    var body: some View {
        Group {
            if let browser {
                BrowserView(browser: browser, session: { model.session })
            } else {
                Color(.systemBackground)
            }
        }
        .onAppear { setUp() }
    }

    private func setUp() {
        guard browser == nil else { return }
        let browser = BrowserModel(session: { [weak model] in model?.session })
        browser.onPageChange = { address, title in
            tabs.update(tab.id, title: title.isEmpty ? address : String(title.prefix(30)), detail: address)
        }
        self.browser = browser
        var start = tab.detail ?? ""
        if start.isEmpty, case .browser(let url) = tab.kind { start = url }
        if !start.isEmpty { browser.open(start) }
    }
}

/// A link from a chat, opened through that chat's host (so `localhost:5173` is the dev server the agent started).
struct BrowserSheet: View {
    @Environment(\.dismiss) private var dismiss
    let session: SSHSession
    let address: String

    @State private var browser: BrowserModel?

    var body: some View {
        NavigationStack {
            Group {
                if let browser {
                    BrowserView(browser: browser, session: { [weak session] in session }, focusWhenEmpty: address.isEmpty)
                }
            }
            .navigationTitle(browser?.title.isEmpty == false ? browser!.title : "Browser")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .onAppear {
            guard browser == nil else { return }
            let browser = BrowserModel(session: { [weak session] in session })
            self.browser = browser
            if !address.isEmpty { browser.open(address) }
        }
    }
}

private struct WebHost: UIViewRepresentable {
    let web: WKWebView
    func makeUIView(context: Context) -> WKWebView { web }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
