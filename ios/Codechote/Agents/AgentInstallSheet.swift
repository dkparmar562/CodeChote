import SwiftUI

/// Runs a setup command on the host (installing a tool, signing in): shows the command first (you can change it),
/// runs it only when you say so, in a real terminal so you see the output and can answer prompts such as a password.
struct CommandSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let note: String
    let session: SSHSession
    let folder: String
    /// Called when you are done, to check again.
    let onFinish: () -> Void

    @State private var command: String
    @State private var terminal: TerminalController?

    init(title: String, command: String, note: String, session: SSHSession, folder: String, onFinish: @escaping () -> Void) {
        self.title = title
        self.note = note
        self.session = session
        self.folder = folder
        self.onFinish = onFinish
        _command = State(initialValue: command)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let terminal {
                    TerminalHost(controller: terminal)
                        .padding(.horizontal, 4)
                        .background(Color(red: 0.08, green: 0.09, blue: 0.11).ignoresSafeArea())
                } else {
                    confirm
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(terminal == nil ? "Cancel" : "Close") { terminal?.stop(); dismiss() }
                }
                if terminal != nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { terminal?.stop(); dismiss(); onFinish() }
                    }
                    ToolbarItem(placement: .principal) {
                        Button {
                            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                        } label: { Image(systemName: "keyboard.chevron.compact.down") }
                        .accessibilityLabel("Hide keyboard")
                    }
                }
            }
        }
        .interactiveDismissDisabled(terminal != nil)
    }

    private var confirm: some View {
        Form {
            Section {
                TextField("Command", text: $command, axis: .vertical)
                    .font(.system(.body, design: .monospaced))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            } header: {
                Text("Runs on \(session.profile.displayName)")
            } footer: {
                Text(note)
            }
            Section {
                Button {
                    let controller = TerminalController(tabID: UUID(), directory: folder, command: command.trimmingCharacters(in: .whitespacesAndNewlines))
                    terminal = controller
                    controller.start(on: session)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { controller.focus() }
                } label: {
                    Label("Run in Terminal", systemImage: "terminal")
                }
                .disabled(command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}

/// Installing an agent's CLI.
struct AgentInstallSheet: View {
    let agent: AgentKind
    let session: SSHSession
    let folder: String
    let onFinish: () -> Void

    var body: some View {
        CommandSheet(
            title: "Install \(agent.title)",
            command: agent.installHint,
            note: "This is the usual install command for \(agent.title). Check it, change it if you need to, and run it. The terminal stays open so you can see what happened, answer prompts, or sign in afterwards by running `\(agent.command ?? agent.rawValue)`.",
            session: session, folder: folder, onFinish: onFinish
        )
    }
}
