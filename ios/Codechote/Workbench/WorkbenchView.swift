import SwiftUI
import UIKit
import WebKit

/// The full VS Code workbench, as one tab. Kept alive while other tabs are shown.
struct WorkbenchTab: View {
    @Environment(AppModel.self) private var model
    let tab: AppTab
    let tabs: TabsModel
    let isSelected: Bool

    /// The main tab reopens what was open last; another window opens its own folder.
    private func pageURL(base: URL) -> URL {
        guard case .window(let folder) = tab.kind else { return base }
        var parts = URLComponents(url: base, resolvingAgainstBaseURL: false)
        parts?.query = nil
        parts?.queryItems = folder.isEmpty ? nil : [URLQueryItem(name: "folder", value: HostPath.toWorkbench(folder, windows: model.isWindowsHost))]
        return parts?.url ?? base
    }

    var body: some View {
        switch model.workbench {
        case .ready(let url):
            WorkbenchPage(url: pageURL(base: url), tab: tab, tabs: tabs, isSelected: isSelected)
        case .idle, .starting:
            let text: String = { if case .starting(let t) = model.workbench { t } else { "Preparing VS Code…" } }()
            VStack(spacing: 14) {
                ProgressView()
                Text(text).font(.footnote).foregroundStyle(.secondary)
                Text("The first time, this downloads VS Code's server onto your host.").font(.caption2).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("VS Code couldn't start", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { model.startWorkbench() }.buttonStyle(.borderedProminent)
            }
        }
    }
}

/// The web page itself, once the server is up.
struct WorkbenchPage: View {
    @Environment(AppModel.self) private var model
    @State private var bridge = WebBridge()
    @State private var keyboardVisible = false
    let url: URL
    let tab: AppTab
    let tabs: TabsModel
    let isSelected: Bool

    var body: some View {
        WorkbenchWebView(url: url, bridge: bridge) { pageURL in
            if case .workbench = tab.kind {
                if let folder = model.pageNavigated(pageURL) { bridge.nav.addRecent(folder) }
            } else if let folder = Self.folder(in: pageURL) {
                // Another window: keep its own folder, without touching the main window's saved state.
                tabs.update(tab.id, detail: folder)
            }
        }
        .background {
            // Behind the web view: the title-bar color at the top, the side-bar color at the bottom,
            // so the safe areas and the glass bars blend with the workbench theme.
            VStack(spacing: 0) {
                (bridge.nav.topColor ?? Color(red: 0.12, green: 0.12, blue: 0.12))
                (bridge.nav.bottomColor ?? Color(red: 0.12, green: 0.12, blue: 0.12))
            }
            .ignoresSafeArea()
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if keyboardVisible && isSelected { KeyBar(bridge: bridge) }
        }
        .onAppear {
            bridge.nav.recentsKey = "recents.\(model.profileKey)"
            bridge.nav.isWindows = model.isWindowsHost
            bridge.nav.lister = { path in try await model.listDirectory(path) }
            WorkbenchSnapshots.shared.register(bridge, for: tab.id, isSelected: isSelected)
            bridge.openWindow = { folder in tabs.open(.window(folder: folder)) }
        }
        .onChange(of: isSelected) { _, selected in if selected { WorkbenchSnapshots.shared.didSelect(tab.id) } }
        .sheet(item: Binding(get: { bridge.nav.pickRequest }, set: { if $0 == nil { bridge.nav.finishPick(nil) } })) { request in
            ResourcePicker(nav: bridge.nav, request: request)
                .presentationDetents([.large])
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardVisible = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardVisible = false }
        .overlay {
            if !bridge.isReady {
                ZStack {
                    Color(red: 0.12, green: 0.12, blue: 0.12)
                    VStack(spacing: 12) {
                        ProgressView().tint(.white)
                        Text("Starting VS Code…").font(.footnote).foregroundStyle(.white.opacity(0.6))
                    }
                }
                .ignoresSafeArea()
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: bridge.isReady)
        .overlay(alignment: .top) {
            if bridge.nav.workbenchLink != "connected" {
                HStack(spacing: 8) {
                    if bridge.nav.workbenchLink == "reconnecting" { ProgressView().controlSize(.small); Text("VS Code is reconnecting…") }
                    else { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange); Text("VS Code lost its connection."); Button("Reload") { bridge.webView?.reload() }.buttonStyle(.bordered).controlSize(.small) }
                }
                .font(.system(size: 14, weight: .medium))
                .padding(.horizontal, 14).padding(.vertical, 9)
                .glass(in: Capsule())
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.smooth, value: bridge.nav.workbenchLink)
        .overlay(alignment: .topTrailing) {
            Menu {
                Menu("UI size", systemImage: "textformat.size") {
                    ForEach(UISize.allCases) { size in
                        Button {
                            UISize.current = size
                            bridge.webView?.pageZoom = size.zoom
                        } label: {
                            if UISize.current == size { Label(size.title, systemImage: "checkmark") } else { Text(size.title) }
                        }
                    }
                }
                Button("Reload", systemImage: "arrow.clockwise") { bridge.webView?.reload() }
            } label: {
                Image(systemName: "ellipsis.circle.fill")
                    .font(.title3).padding(8).foregroundStyle(.secondary.opacity(0.7))
            }
        }
    }
}

extension WorkbenchPage {
    /// The folder a workbench URL opens (`?folder=/path`), as a host path.
    static func folder(in url: URL?) -> String? {
        guard let url, let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "folder" })?.value else { return nil }
        return HostPath.fromWorkbench(value, windows: value.range(of: #"^/[A-Za-z]:"#, options: .regularExpression) != nil)
    }
}

/// Every open VS Code page by tab, so the new-tab page and file opening can reach the right one.
@MainActor
final class WorkbenchSnapshots {
    static let shared = WorkbenchSnapshots()
    private struct Entry { weak var bridge: WebBridge? }
    private var entries: [UUID: Entry] = [:]
    /// The VS Code tab that was in front most recently.
    private(set) var activeTab: UUID?

    var bridge: WebBridge? { activeTab.flatMap { entries[$0]?.bridge } }

    func register(_ bridge: WebBridge, for tab: UUID, isSelected: Bool) {
        entries[tab] = Entry(bridge: bridge)
        if isSelected || activeTab == nil { activeTab = tab }
    }

    func bridge(for tab: UUID) -> WebBridge? { entries[tab]?.bridge }
    func didSelect(_ tab: UUID) { activeTab = tab }

    /// The VS Code window whose screens to list: the one in front, else the last one used.
    func frontWindow(in tabs: TabsModel) -> (tabID: UUID, title: String, nav: NavModel)? {
        func isVSCode(_ tab: AppTab) -> Bool { if case .workbench = tab.kind { return true }; if case .window = tab.kind { return true }; return false }
        let candidates = [tabs.tabs.first { $0.id == tabs.selectedID && isVSCode($0) }, tabs.tabs.first { $0.id == activeTab }, tabs.tabs.first(where: isVSCode)]
        for case let tab? in candidates {
            if let bridge = entries[tab.id]?.bridge { return (tab.id, tab.title, bridge.nav) }
        }
        return nil
    }
}

struct KeyBar: View {
    let bridge: WebBridge

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                keyButton("esc") { bridge.key("Escape") }
                keyButton("tab") { bridge.key("Tab") }
                Button { bridge.toggleCtrl() } label: {
                    Text("ctrl").frame(minWidth: 34)
                }
                .buttonStyle(.borderedProminent)
                .tint(bridge.ctrlActive ? .blue : .gray)
                keyButton("^C") { bridge.key("c", ctrl: true) }
                keyButton("^D") { bridge.key("d", ctrl: true) }
                keyButton("↑") { bridge.key("ArrowUp") }
                keyButton("↓") { bridge.key("ArrowDown") }
                keyButton("←") { bridge.key("ArrowLeft") }
                keyButton("→") { bridge.key("ArrowRight") }
                ForEach(["|", "/", "~", "-", "_", "\\", "$", "&", "*", "{", "}", "[", "]", "<", ">"], id: \.self) { ch in
                    keyButton(ch) { bridge.text(ch) }
                }
                keyButton("⌄") { bridge.dismissKeyboard() }
            }
            .padding(.horizontal, 8)
        }
        .frame(height: 44)
        .glass(in: Capsule())
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
    }

    private func keyButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).frame(minWidth: 30) }
            .buttonStyle(.bordered)
            .tint(.gray)
    }
}

struct WorkbenchWebView: UIViewRepresentable {
    let url: URL
    let bridge: WebBridge
    /// Called each time the page navigates (e.g. after opening a folder).
    var onNavigate: (URL?) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(bridge: bridge, onNavigate: onNavigate) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.limitsNavigationsToAppBoundDomains = true   // enables service workers for the domains in Info.plist
        config.userContentController.addUserScript(
            WKUserScript(source: WebBridge.script, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        )
        config.userContentController.add(bridge, name: "cc")
        let web = WKWebView(frame: .zero, configuration: config)
        web.isInspectable = true
        web.pageZoom = UISize.current.zoom
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.scrollView.bounces = false
        web.isOpaque = false
        web.backgroundColor = UIColor(red: 0.12, green: 0.12, blue: 0.12, alpha: 1)
        web.uiDelegate = context.coordinator
        web.navigationDelegate = context.coordinator
        bridge.webView = web
        context.coordinator.loaded = url
        web.load(URLRequest(url: url))
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        if context.coordinator.loaded != url {
            context.coordinator.loaded = url
            web.load(URLRequest(url: url))
        }
    }

    final class Coordinator: NSObject, WKUIDelegate, WKNavigationDelegate {
        var loaded: URL?
        private let bridge: WebBridge
        private let onNavigate: (URL?) -> Void

        init(bridge: WebBridge, onNavigate: @escaping (URL?) -> Void) {
            self.bridge = bridge
            self.onNavigate = onNavigate
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            // A new page load (e.g. opening a folder): show the loading screen until it is ready.
            Task { @MainActor in bridge.isReady = false }
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            let url = webView.url
            Task { @MainActor in onNavigate(url) }
        }

        private func isLocal(_ url: URL?) -> Bool {
            guard let host = url?.host else { return true }
            return host == "127.0.0.1" || host == "localhost"
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            #if targetEnvironment(simulator)
            // `-devJS "<script>"`: run a script a few seconds after load (taps for simulator tests).
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-devJS"), i + 1 < args.count {
                let script = args[i + 1]
                DispatchQueue.main.asyncAfter(deadline: .now() + 9) {
                    webView.evaluateJavaScript(script) { result, error in
                        print("[web] devJS \(result ?? "nil") \(error.map { "err=\($0)" } ?? "")")
                    }
                }
            }
            #endif
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            print("[web] navigation failed: \(error)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            print("[web] provisional navigation failed: \(error)")
        }

        func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                     completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            completionHandler(.performDefaultHandling, nil)
        }

        /// `window.open` / target=_blank to an external site goes to Safari.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            guard let url = navigationAction.request.url else { return nil }
            if !isLocal(url) {
                UIApplication.shared.open(url)
            } else if let folder = WorkbenchPage.folder(in: url) {
                // "Open in new window": its own tab, not a page stacked on this one.
                Task { @MainActor in bridge.openWindow?(folder) }
            }
            return nil
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated, let url = action.request.url,
               !isLocal(url), url.scheme == "http" || url.scheme == "https" {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }
    }
}


/// How large the workbench is drawn. Larger sizes make rows and buttons easier to hit with a finger.
enum UISize: String, CaseIterable, Identifiable {
    case compact, regular, large, extraLarge
    var id: String { rawValue }

    var title: String {
        switch self {
        case .compact: "Compact"
        case .regular: "Regular"
        case .large: "Large"
        case .extraLarge: "Extra large"
        }
    }

    var zoom: CGFloat {
        switch self {
        case .compact: 1.0
        case .regular: 1.1
        case .large: 1.25
        case .extraLarge: 1.4
        }
    }

    private static let key = "ui.size"

    static var current: UISize {
        get { UserDefaults.standard.string(forKey: key).flatMap(UISize.init(rawValue:)) ?? .regular }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}
