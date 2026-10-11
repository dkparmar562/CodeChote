import SwiftTerm
import SwiftUI
import UIKit

/// Owns one native terminal: the SwiftTerm view and the SSH shell behind it.
@MainActor
final class TerminalController: NSObject, TerminalViewDelegate {
    let view: TerminalView
    private var shell: ShellSession?
    private let sessionName: String
    private var directory: String
    /// A program to start in the shell (an agent's CLI); the shell stays open after it exits.
    private let command: String?
    var onTitle: ((String) -> Void)?
    /// The program rang the terminal bell (agent CLIs do this when they want you).
    var onBell: (() -> Void)?
    /// A link was tapped in the terminal. Return true if it was handled (opened in the browser tab).
    var onOpenLink: ((URL) -> Bool)?
    var onState: ((State) -> Void)?

    enum State { case connecting, running, ended(String?) }

    init(tabID: UUID, directory: String, command: String? = nil) {
        self.command = command
        sessionName = "cc-" + tabID.uuidString.prefix(8).lowercased()
        self.directory = directory
        view = TerminalView(frame: .zero)
        super.init()
        view.terminalDelegate = self
        view.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        view.nativeBackgroundColor = UIColor(red: 0.08, green: 0.09, blue: 0.11, alpha: 1)
        view.nativeForegroundColor = UIColor(red: 0.85, green: 0.87, blue: 0.9, alpha: 1)
        view.backgroundColor = view.nativeBackgroundColor
    }

    /// With tmux on the host, the shell lives in a named session so it survives dropped connections
    /// (iOS suspends the app, the network changes). Without it, a plain login shell.
    private func bootstrap(for os: HostOS) -> String {
        if os.isWindows {
            // Works from cmd.exe and from PowerShell, whichever the host's SSH starts. No tmux on Windows.
            let run = command.map { "; \($0)" } ?? ""
            return "powershell -NoLogo -NoExit -Command \"Set-Location -LiteralPath \(PS.quote(directory)); Clear-Host\(run)\""
        }
        let dir = shellQuote(directory)
        // A login shell runs the program (so nvm/brew PATH entries apply), then stays as an ordinary shell.
        let login = "\"${SHELL:-/bin/sh}\""
        let program = command.map { "\(login) -lc \(shellQuote("\($0); exec \(login) -l"))" }
        let tmuxProgram = program.map { " " + shellQuote($0) } ?? ""
        let plain = program.map { "exec \($0)" } ?? "clear"
        return "stty -echo; if command -v tmux >/dev/null 2>&1; then exec tmux new-session -A -s \(sessionName) -c \(dir)\(tmuxProgram); else stty echo; cd \(dir) && \(plain); fi"
    }

    func start(on session: SSHSession) {
        shell?.close()
        onState?(.connecting)
        let shell = session.openShell(cols: max(view.getTerminal().cols, 80), rows: max(view.getTerminal().rows, 24), bootstrap: bootstrap(for: session.os))
        shell.onData = { [weak self] data in
            DispatchQueue.main.async {
                self?.view.feed(byteArray: ArraySlice(data))
                self?.scanForPrompt(data)
            }
        }
        shell.onClose = { [weak self] error in
            DispatchQueue.main.async { self?.onState?(.ended(error.map { String(describing: $0) })) }
        }
        self.shell = shell
        shell.start()
        onState?(.running)
        // Tell the host the real size once the view has been laid out.
        let terminal = view.getTerminal()
        shell.resize(cols: terminal.cols, rows: terminal.rows)
        #if targetEnvironment(simulator)
        // `-devTermInput 'ls\n'`: type into the terminal a moment after it starts (simulator tests).
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-devTermInput"), i + 1 < args.count {
            let text = args[i + 1].replacingOccurrences(of: "\\n", with: "\n")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak shell] in shell?.send(Data(text.utf8)) }
        }
        #endif
    }

    func stop() { shell?.close(); shell = nil }

    /// Types text into the shell, as if from the keyboard.
    func sendText(_ text: String) { shell?.send(Data(text.utf8)) }

    /// The program rang the bell, or printed something that reads like it is waiting for you.
    var onAttention: ((String) -> Void)?
    private var recentOutput = ""
    private static let promptCues = ["(y/n)", "[y/n]", "(yes/no)", "do you want to", "waiting for your", "press enter", "allow this", "proceed?", "approve?"]

    private func scanForPrompt(_ data: Data) {
        guard onAttention != nil else { return }
        recentOutput = String((recentOutput + String(decoding: data, as: UTF8.self)).suffix(300)).lowercased()
        if let cue = Self.promptCues.first(where: { recentOutput.contains($0) }) {
            recentOutput = ""
            onAttention?(cue)
        }
    }

    func focus() { _ = view.becomeFirstResponder() }

    // MARK: TerminalViewDelegate

    func send(source: TerminalView, data: ArraySlice<UInt8>) { shell?.send(Data(data)) }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) { shell?.resize(cols: newCols, rows: newRows) }
    func setTerminalTitle(source: TerminalView, title: String) { onTitle?(title) }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link) else { return }
        if onOpenLink?(url) != true { UIApplication.shared.open(url) }
    }
    func clipboardCopy(source: TerminalView, content: Data) {
        UIPasteboard.general.string = String(decoding: content, as: UTF8.self)
    }
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    func bell(source: TerminalView) { onBell?() }
}

struct TerminalHost: UIViewRepresentable {
    let controller: TerminalController
    func makeUIView(context: Context) -> TerminalView { controller.view }
    func updateUIView(_ uiView: TerminalView, context: Context) {}
}

struct TerminalTab: View {
    @Environment(AppModel.self) private var model
    let tab: AppTab
    let tabs: TabsModel
    let isSelected: Bool

    @State private var controller: TerminalController?
    @State private var ended: String??

    var body: some View {
        ZStack {
            Color(red: 0.08, green: 0.09, blue: 0.11).ignoresSafeArea()
            if let controller {
                TerminalHost(controller: controller)
                    .padding(.horizontal, 4)
            }
            if let ended {
                VStack(spacing: 12) {
                    Image(systemName: "bolt.horizontal.circle").font(.system(size: 34)).foregroundStyle(.secondary)
                    Text("Session ended").font(.headline).foregroundStyle(.white)
                    if let message = ended { Text(message).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 24) }
                    Button("Reconnect") { restart() }.buttonStyle(.borderedProminent)
                }
                .padding(24)
                .glass(in: RoundedRectangle(cornerRadius: 24))
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // Agents ask for approval with a number, y/n, Enter or Esc: keys the phone keyboard makes awkward.
            if case .agentTerminal = tab.kind, let controller { AgentAnswerBar { controller.sendText($0) } }
        }
        .onAppear { startIfNeeded() }
        .onChange(of: isSelected) { _, selected in
            if selected { startIfNeeded(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { controller?.focus() } }
        }
        .onChange(of: model.connection) { _, state in
            // After the connection came back, reattach (the tmux session, if any, is still there).
            if state == .connected, ended != nil { restart() }
        }
    }

    private func startIfNeeded() {
        guard controller == nil, let session = model.session else { return }
        let directory = tab.detail?.isEmpty == false ? tab.detail! : model.rootFolder
        var command: String?
        if case .agentTerminal(let agent) = tab.kind { command = agent.command }
        let controller = TerminalController(tabID: tab.id, directory: directory, command: command)
        if case .agentTerminal = tab.kind {} else {
            controller.onTitle = { title in tabs.update(tab.id, title: title.isEmpty ? "Terminal" : title) }
        }
        if case .agentTerminal(let agent) = tab.kind {
            let id = tab.id
            Notifier.shared.requestIfNeeded()
            var last = Date.distantPast
            let notify: () -> Void = {
                guard Date().timeIntervalSince(last) > 20 else { return }   // a CLI can ring or prompt repeatedly
                last = Date()
                Notifier.shared.needsAttention(tab: id, title: agent.title, body: "Needs your attention in the terminal.")
            }
            controller.onBell = notify
            controller.onAttention = { _ in notify() }
        }
        // http links (a dev server's "Local: http://localhost:5173") open in the browser tab, from the host's side.
        controller.onOpenLink = { url in
            guard url.scheme == "http" else { return false }
            tabs.open(.browser(url: url.absoluteString))
            return true
        }
        controller.onState = { state in
            if case .ended(let message) = state { ended = .some(message) } else { ended = nil }
        }
        self.controller = controller
        controller.start(on: session)
        if isSelected { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { controller.focus() } }
    }

    private func restart() {
        guard let session = model.session, let controller else { return }
        ended = nil
        controller.start(on: session)
    }
}
