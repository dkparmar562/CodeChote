import Observation
import SwiftUI
import WebKit

/// Receives the viewer page's messages without keeping the model alive.
private final class ScreenMessageProxy: NSObject, WKScriptMessageHandler {
    weak var model: ScreenModel?
    init(model: ScreenModel) { self.model = model }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        Task { @MainActor in self.model?.handle(body) }
    }
}

/// The host's screen, shown through the bundled VNC viewer and controlled by touch.
@MainActor
@Observable
final class ScreenModel {
    enum State: Equatable {
        case starting
        case connecting
        case connected
        case needsCredentials(askUser: Bool)
        case failed(String)
    }

    var state: State = .starting
    var desktopName = ""
    var panMode = false
    var fitted = true
    var held: Set<String> = []
    var keyboardShown = false

    let webView: WKWebView
    private let credentialKey: String
    private var sentSaved = false
    private(set) var port: Int

    init(credentialKey: String, port: Int) {
        self.credentialKey = credentialKey
        self.port = port
        let config = WKWebViewConfiguration()
        webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = UIColor(white: 0.07, alpha: 1)
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isInspectable = true
        // The content controller is shared with the configuration the web view was made from.
        webView.configuration.userContentController.add(ScreenMessageProxy(model: self), name: "rd")
    }

    func start(on session: SSHSession) async {
        state = .starting
        do {
            let url = try await session.startScreenViewer(vncPort: port)
            state = .connecting
            webView.load(URLRequest(url: url))
        } catch {
            state = .failed("Couldn't start the viewer: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
        }
    }

    func reconnect(port newPort: Int? = nil, session: SSHSession?) {
        if let newPort { port = newPort }
        guard let session else { return }
        Task { await start(on: session) }
    }

    // MARK: Messages from the page

    func handle(_ message: [String: Any]) {
        switch message["type"] as? String {
        case "connect":
            state = .connected
        case "disconnect":
            if state == .connected { state = .failed("The connection to the screen ended.") }
            else if case .failed = state {} else { state = .failed("Nothing answered on port \(port) of the host.") }
        case "securityfailure":
            Keychain.delete(credentialKey)
            state = .failed((message["reason"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "The host refused the password.")
        case "credentials":
            let needs = message["needs"] as? [String] ?? []
            if !sentSaved, let saved = Keychain.get(credentialKey), let parts = Optional(saved.components(separatedBy: "\n")), parts.count == 2 {
                sentSaved = true
                sendCredentials(user: parts[0], password: parts[1])
            } else {
                state = .needsCredentials(askUser: needs.contains("username"))
            }
        case "name": desktopName = message["name"] as? String ?? ""
        case "clipboard": if let text = message["text"] as? String { UIPasteboard.general.string = text }
        case "modifiers": held = Set(message["held"] as? [String] ?? [])
        case "keyboard": keyboardShown = message["shown"] as? Bool ?? false
        case "log": print("[screen] \(message["text"] as? String ?? "")")
        default: break
        }
    }

    // MARK: Actions

    func submit(user: String, password: String) {
        Keychain.set("\(user)\n\(password)", for: credentialKey)
        sendCredentials(user: user, password: password)
        state = .connecting
    }

    private func sendCredentials(user: String, password: String) {
        js("window.cc.credentials(\(Self.quote(user)), \(Self.quote(password)))")
    }

    func press(_ key: String) { js("window.cc.press(\(Self.quote(key)))") }
    func toggleModifier(_ key: String) { js("window.cc.toggleModifier(\(Self.quote(key)))") }
    func ctrlAltDel() { js("window.cc.ctrlAltDel()") }
    func paste() { if let text = UIPasteboard.general.string { js("window.cc.paste(\(Self.quote(text)))") } }
    func hideKeyboard() { js("window.cc.hideKeyboard()") }

    func togglePan() {
        panMode.toggle()
        js("window.cc.mode(\(Self.quote(panMode ? "view" : "control")))")
    }

    func toggleFit() {
        fitted.toggle()
        js("window.cc.fit(\(fitted))")
    }

    func disconnect() { js("window.cc.disconnect()") }

    private func js(_ source: String) { webView.evaluateJavaScript(source, completionHandler: nil) }

    private static func quote(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [text])) ?? Data("[\"\"]".utf8)
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }
}

struct RemoteScreenTab: View {
    @Environment(AppModel.self) private var model
    let tab: AppTab
    let tabs: TabsModel
    let isSelected: Bool

    @State private var screen: ScreenModel?
    @State private var user = ""
    @State private var password = ""
    @State private var portText = ""
    @State private var settingUp = false

    var body: some View {
        ZStack {
            Color(white: 0.07).ignoresSafeArea()
            if let screen {
                ScreenWebView(web: screen.webView)
                overlay(for: screen)
            }
        }
        .overlay(alignment: .top) { if let screen, screen.state == .connected { toolbar(screen) } }
        .onAppear { setUp() }
        .sheet(isPresented: $settingUp) {
            if let session = model.session {
                CommandSheet(title: "Set Up Screen Sharing", command: setup.command, note: setup.note, session: session, folder: model.rootFolder) {
                    screen?.reconnect(port: Int(portText), session: model.session)
                }
            }
        }
        .alert("Sign in to the screen", isPresented: Binding(get: { needsCredentials }, set: { _ in })) {
            if askUser { TextField("User name", text: $user).textInputAutocapitalization(.never).autocorrectionDisabled() }
            SecureField("Password", text: $password)
            Button("Connect") { screen?.submit(user: user, password: password); password = "" }
            Button("Cancel", role: .cancel) { screen?.disconnect() }
        } message: {
            Text(askUser ? "macOS asks for the name and password of an account on that Mac." : "The password you set for the VNC server on the host.")
        }
    }

    private var needsCredentials: Bool { if case .needsCredentials = screen?.state { true } else { false } }
    private var askUser: Bool { if case .needsCredentials(let ask) = screen?.state { ask } else { false } }

    private func setUp() {
        guard screen == nil, let host = model.session else { return }
        var port = 5900
        if case .screen(let p) = tab.kind { port = p }
        portText = String(port)
        let created = ScreenModel(credentialKey: "screen.\(model.profileKey).\(port)", port: port)
        screen = created
        tabs.update(tab.id, title: "Screen", detail: host.profile.displayName)
        Task { await created.start(on: host) }
    }

    @ViewBuilder
    private func overlay(for screen: ScreenModel) -> some View {
        switch screen.state {
        case .starting, .connecting, .needsCredentials:
            VStack(spacing: 12) {
                ProgressView().tint(.white)
                Text(screen.state == .starting ? "Starting the viewer…" : "Connecting to the screen…").font(.footnote).foregroundStyle(.white.opacity(0.7))
            }
        case .connected:
            EmptyView()
        case .failed(let message):
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Label(message, systemImage: "display.trianglebadge.exclamationmark").font(.headline).foregroundStyle(.white)
                    Text(setupHelp).font(.footnote).foregroundStyle(.white.opacity(0.75))
                    Button { settingUp = true } label: { Label("Set Up Screen Sharing…", systemImage: "wrench.and.screwdriver") }
                        .buttonStyle(.bordered).tint(.white)
                    HStack {
                        Text("VNC port").foregroundStyle(.white.opacity(0.75))
                        TextField("5900", text: $portText).keyboardType(.numberPad).textFieldStyle(.roundedBorder).frame(width: 90)
                        Button("Try Again") { screen.reconnect(port: Int(portText), session: model.session) }.buttonStyle(.borderedProminent)
                    }
                }
                .padding(20)
                .frame(maxWidth: 520, alignment: .leading)
            }
        }
    }

    /// The command that gets a screen server running, for the host's system, and what to expect from it.
    private var setup: (command: String, note: String) {
        switch model.session?.os ?? .linux {
        case .macos:
            return ("sudo launchctl enable system/com.apple.screensharing && sudo launchctl bootstrap system /System/Library/LaunchDaemons/com.apple.screensharing.plist",
                    "Turns on the Mac's own Screen Sharing (it asks for your Mac password). If macOS says it's already loaded or not allowed, turn it on in System Settings → General → Sharing instead. You sign in with a Mac account's name and password.")
        case .windows:
            return ("winget install --id GlavSoft.TightVNC -e --accept-package-agreements --accept-source-agreements",
                    "Installs TightVNC Server. Afterwards, open TightVNC Server on the PC once to set its password; it then listens on port 5900.")
        case .linux:
            return ("(command -v x11vnc >/dev/null || sudo apt-get install -y x11vnc || sudo dnf install -y x11vnc || sudo pacman -S --noconfirm x11vnc) && mkdir -p ~/.vnc && x11vnc -storepasswd ~/.vnc/passwd && x11vnc -display :0 -auth guess -localhost -forever -shared -bg -rfbauth ~/.vnc/passwd",
                    "Installs x11vnc if needed, asks you for a password to use from the phone, and starts it for the desktop on display :0, listening only on the host itself. For a Wayland desktop, use wayvnc instead.")
        }
    }

    /// How to get a screen server running, for the host's system.
    private var setupHelp: String {
        switch model.session?.os ?? .linux {
        case .macos:
            "On the Mac: System Settings → General → Sharing → turn on Screen Sharing, then open its info button (ⓘ) and switch on “VNC viewers may control screen with password”. Set a password. You will be asked for a Mac account name and password, or that VNC password."
        case .windows:
            "Windows has no VNC server of its own. Install one such as TightVNC or TigerVNC Server on the PC, set a password, and keep it listening on port 5900. Windows' built-in Remote Desktop uses a different protocol that this viewer can't speak."
        case .linux:
            "Install and start a VNC server on the desktop you want to see, for example `x11vnc -display :0 -localhost -usepw` (X11) or `wayvnc` (Wayland). It only needs to listen on the host itself; the app reaches it through SSH."
        }
    }

    private func toolbar(_ screen: ScreenModel) -> some View {
        HStack(spacing: 8) {
            barButton(screen.panMode ? "hand.draw.fill" : "cursorarrow.click", label: screen.panMode ? "Pan and zoom: on" : "Touch controls the mouse") { screen.togglePan() }
            barButton(screen.fitted ? "arrow.up.left.and.down.right.magnifyingglass" : "rectangle.arrowtriangle.2.inward", label: screen.fitted ? "Show actual size" : "Fit to screen") { screen.toggleFit() }
            Menu {
                Section("Hold for the next key") {
                    ForEach(["Control", "Alt", "Shift", "Meta"], id: \.self) { name in
                        Button { screen.toggleModifier(name) } label: {
                            if screen.held.contains(name) { Label(modifierTitle(name), systemImage: "checkmark") } else { Text(modifierTitle(name)) }
                        }
                    }
                }
                Section("Keys") {
                    ForEach(["Escape", "Tab", "Enter", "Backspace", "Delete"], id: \.self) { key in Button(key) { screen.press(key) } }
                    Menu("Arrows") { ForEach(["ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight", "Home", "End", "PageUp", "PageDown"], id: \.self) { key in Button(key) { screen.press(key) } } }
                    Menu("Function Keys") { ForEach(1...12, id: \.self) { n in Button("F\(n)") { screen.press("F\(n)") } } }
                }
                Button("Ctrl-Alt-Del", systemImage: "command") { screen.ctrlAltDel() }
                Button("Paste from This Phone", systemImage: "doc.on.clipboard") { screen.paste() }
            } label: {
                Image(systemName: "keyboard.chevron.compact.down").font(.system(size: 16, weight: .semibold)).frame(width: 40, height: 40)
            }
            .glass(in: Circle(), interactive: true)
            Spacer(minLength: 0)
            if !screen.desktopName.isEmpty { Text(screen.desktopName).font(.caption).lineLimit(1).foregroundStyle(.white.opacity(0.7)) }
            barButton("xmark", label: "Disconnect") { screen.disconnect() }
        }
        .padding(.horizontal, 12).padding(.top, 6)
    }

    private func modifierTitle(_ name: String) -> String {
        switch name {
        case "Control": "Ctrl"
        case "Meta": model.session?.os == .macos ? "Cmd" : "Win"
        default: name
        }
    }

    private func barButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 16, weight: .semibold)).frame(width: 40, height: 40)
        }
        .buttonStyle(.plain)
        .glass(in: Circle(), interactive: true)
        .accessibilityLabel(label)
    }
}

private struct ScreenWebView: UIViewRepresentable {
    let web: WKWebView
    func makeUIView(context: Context) -> WKWebView { web }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
