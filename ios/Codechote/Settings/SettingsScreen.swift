import SwiftUI
import UserNotifications

/// App settings, and what the app is and is built from.
struct SettingsScreen: View {
    @Environment(AppModel.self) private var model
    @State private var usage = UsageStore.shared
    @State private var notifications: UNAuthorizationStatus?
    @State private var uiSize = UISize.current
    @State private var clearedCache = false
    @State private var modelsChanged = 0

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(AgentKind.chatKinds) { agent in
                        NavigationLink { AgentDefaults(agent: agent) { modelsChanged += 1 } } label: {
                            HStack(spacing: 12) {
                                AgentIcon(agent: agent, size: 28)
                                Text(agent.title)
                                Spacer()
                                Text(agent.selectedModelTitle).foregroundStyle(.secondary).id(modelsChanged)
                            }
                        }
                    }
                } header: { Text("Agents") } footer: { Text("The model and the access level a new chat starts with. Each chat can change them.") }

                Section {
                    Toggle("Show Usage in Chats", isOn: $usage.showUsage)
                } header: { Text("Usage") } footer: {
                    Text("At the end of the chats list: each agent's account and limits, with when they reset. Claude Code's 5-hour and weekly limits come from Anthropic's usage service, asked by the host with Claude Code's own sign-in (it stays on the host). Copilot's quota comes from GitHub through gh. Agents that don't publish limits show their account only.")
                }

                Section {
                    Toggle("Keep Screen On While Working", isOn: Binding(get: { ScreenAwake.enabled }, set: { ScreenAwake.enabled = $0 }))
                } footer: {
                    Text("While an agent or a run is working and the app is open, the iPhone doesn't lock, so it isn't paused.")
                }

                Section {
                    HStack {
                        Text("Notifications")
                        Spacer()
                        Text(notificationStatus).foregroundStyle(.secondary)
                    }
                    Button("Open iOS Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                } header: { Text("Notifications") } footer: {
                    Text("You are told when an agent finishes, asks you something or needs approval. iOS pauses the app a little after you leave it, so a reply that ends later is noticed when you come back.")
                }

                Section("VS Code") {
                    Picker("Text Size", selection: $uiSize) {
                        ForEach(UISize.allCases) { Text($0.title).tag($0) }
                    }
                    .onChange(of: uiSize) { _, size in
                        UISize.current = size
                        WorkbenchSnapshots.shared.bridge?.webView?.pageZoom = size.zoom
                    }
                }

                Section {
                    Button(clearedCache ? "Cleared" : "Clear Saved Chats", role: .destructive) {
                        ChatCache.clearAll()
                        clearedCache = true
                    }
                    .disabled(clearedCache)
                } header: { Text("Storage") } footer: {
                    Text("Chats are kept on this phone so they open at once. Clearing only removes these copies; the conversations stay on your hosts.")
                }

                Section("About") {
                    row("Version", Self.appVersion)
                    if let vscode = Self.vscodeVersion { row("VS Code", vscode) }
                    row("Developer", "Dhruvesh Parmar")
                    NavigationLink("Privacy") { PrivacyNotes() }
                    NavigationLink("Open-Source Licenses") { LicensesList() }
                }
            }
            .navigationTitle("Settings")
            .task { notifications = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus }
        }
    }

    private var notificationStatus: String {
        switch notifications {
        case .authorized, .provisional, .ephemeral: "On"
        case .denied: "Off"
        case .notDetermined: "Not asked yet"
        default: "…"
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack { Text(title); Spacer(); Text(value).foregroundStyle(.secondary).textSelection(.enabled) }
    }

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    /// From the bundled VS Code's product.json: its version and the first characters of its commit.
    static var vscodeVersion: String? {
        guard let root = SSHSession.bundledUIRoot,
              let data = try? Data(contentsOf: root.appendingPathComponent("product.json")),
              let product = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let version = product["version"] as? String
        let commit = (product["commit"] as? String).map { String($0.prefix(7)) }
        return [version, commit].compactMap { $0 }.joined(separator: " · ").nonEmpty
    }
}

/// An agent's defaults for new chats.
private struct AgentDefaults: View {
    let agent: AgentKind
    let onChange: () -> Void
    @State private var mode: PermissionMode = .acceptEdits

    var body: some View {
        Form {
            Section("Model") {
                NavigationLink {
                    ModelPicker(agent: agent) { _ in onChange() }
                } label: {
                    HStack { Text("Model"); Spacer(); Text(agent.selectedModelTitle).foregroundStyle(.secondary) }
                }
            }
            Section {
                Picker("Access", selection: $mode) {
                    ForEach(PermissionMode.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                .onChange(of: mode) { _, value in UserDefaults.standard.set(value.rawValue, forKey: "agent.mode.\(agent.rawValue)") }
            } header: { Text("What it may do") } footer: { Text(mode.detail) }
            if let command = agent.command {
                Section {
                    LabeledContent("Command", value: command)
                    LabeledContent("Install", value: agent.installHint).font(.footnote)
                } header: { Text("On the host") }
            }
        }
        .navigationTitle(agent.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            mode = UserDefaults.standard.string(forKey: "agent.mode.\(agent.rawValue)").flatMap(PermissionMode.init(rawValue:)) ?? .acceptEdits
        }
    }
}

private struct PrivacyNotes: View {
    var body: some View {
        Form {
            Section {
                Text("Codechote talks only to the hosts you add, over SSH. There is no account, no server of ours and no analytics.")
                Text("Passwords and keys are kept in this phone's Keychain. Chats are read from your hosts and a copy is kept on the phone so they open quickly.")
                Text("Agents run on your hosts with their own sign-ins. Turning on Claude plan usage makes the host ask Anthropic's usage service with Claude Code's own sign-in; it is off until you turn it on.")
            }
        }
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct LicensesList: View {
    private let items: [(String, String, String)] = [
        ("Visual Studio Code (Code - OSS)", "MIT", "The editor in the VS Code tab and the server on the host."),
        ("noVNC", "MPL 2.0", "The remote screen viewer."),
        ("SwiftNIO", "Apache 2.0", "Networking."),
        ("Citadel", "MIT", "SSH."),
        ("SwiftNIO SSH", "Apache 2.0", "SSH protocol."),
        ("Swift Crypto", "Apache 2.0", "Cryptography."),
        ("SwiftTerm", "MIT", "The terminal."),
    ]

    var body: some View {
        List(items, id: \.0) { name, license, use in
            VStack(alignment: .leading, spacing: 3) {
                HStack { Text(name).font(.subheadline.weight(.semibold)); Spacer(); Text(license).font(.caption).foregroundStyle(.secondary) }
                Text(use).font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Licenses")
        .navigationBarTitleDisplayMode(.inline)
    }
}
