import SwiftUI

struct ModelOption: Identifiable, Hashable {
    /// What is passed to the CLI. Empty means "the CLI's own default".
    let id: String
    let title: String
}

/// The model each agent uses. Names are passed straight to the CLI, so any name it accepts works ("Custom…").
/// The presets are a starting point and may lag behind what each provider has released.
extension AgentKind {
    var modelPresets: [ModelOption] {
        let presets: [(String, String)]
        switch self {
        case .claude: presets = [("opus", "Opus"), ("sonnet", "Sonnet"), ("haiku", "Haiku")]
        case .codex: presets = [("gpt-5-codex", "GPT-5 Codex"), ("gpt-5", "GPT-5")]
        case .cursor: presets = [("auto", "Auto"), ("gpt-5", "GPT-5"), ("sonnet-4", "Claude Sonnet 4")]
        case .gemini: presets = [("gemini-2.5-pro", "Gemini 2.5 Pro"), ("gemini-2.5-flash", "Gemini 2.5 Flash")]
        case .copilot: presets = [("claude-sonnet-4", "Claude Sonnet 4"), ("gpt-5", "GPT-5")]
        case .opencode, .kilo, .antigravity: presets = []
        }
        return [ModelOption(id: "", title: "Default")] + presets.map { ModelOption(id: $0.0, title: $0.1) }
    }

    /// `opencode models` and `kilo models` list what is configured on the host.
    var canListModels: Bool { self == .opencode || self == .kilo }

    private var modelKey: String { "agent.model.\(rawValue)" }

    var selectedModel: String {
        get { UserDefaults.standard.string(forKey: modelKey) ?? "" }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: modelKey) }
    }

    /// A short name for chips and rows.
    var selectedModelTitle: String {
        let id = selectedModel
        return id.isEmpty ? "Default" : (modelPresets.first { $0.id == id }?.title ?? id)
    }

    /// The flag that selects a model for this CLI.
    func modelArguments(_ model: String) -> [String] {
        guard !model.isEmpty else { return [] }
        switch self {
        case .claude, .cursor, .copilot: return ["--model", model]
        case .codex, .gemini, .opencode, .kilo: return ["-m", model]
        case .antigravity: return []
        }
    }
}

/// Choosing a model: presets, models the host reports (OpenCode, Kilo), or any name typed in.
struct ModelPicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let agent: AgentKind
    var onChange: (String) -> Void = { _ in }

    @State private var selected = ""
    @State private var custom = ""
    @State private var hostModels: [String] = []
    @State private var loading = false

    var body: some View {
        List {
            Section {
                ForEach(agent.modelPresets) { option in row(option.id, option.title) }
                ForEach(hostModels.filter { id in !agent.modelPresets.contains { $0.id == id } }, id: \.self) { row($0, $0) }
                if loading { HStack { ProgressView(); Text("Asking the host…").foregroundStyle(.secondary) } }
            } header: { Text("Models") } footer: {
                Text("Names are passed to \(agent.command ?? agent.title) as they are, so use whatever it accepts.")
            }
            Section("Custom") {
                HStack {
                    TextField(agent == .opencode || agent == .kilo ? "provider/model" : "Model name", text: $custom)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .onSubmit { choose(custom.trimmingCharacters(in: .whitespaces)) }
                    Button("Use") { choose(custom.trimmingCharacters(in: .whitespaces)) }.disabled(custom.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .navigationTitle("\(agent.title) model")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { selected = agent.selectedModel }
        .task {
            guard agent.canListModels, let host = model.session, !host.os.isWindows, let cli = await CLIChatAdapter(kind: agent).locateCLI(on: host) else { return }
            loading = true
            if let result = try? await host.exec("\(shellQuote(cli)) models 2>/dev/null </dev/null"), result.succeeded {
                hostModels = result.stdout.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.contains("/") && !$0.contains(" ") }
            }
            loading = false
        }
    }

    private func row(_ id: String, _ title: String) -> some View {
        Button { choose(id) } label: {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                if selected == id { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
            }
        }
    }

    private func choose(_ id: String) {
        guard !id.contains(where: \.isWhitespace) else { return }
        selected = id
        agent.selectedModel = id
        onChange(id)
        dismiss()
    }
}

/// A chip that shows the model and lets you change it, for the chat header.
struct ModelChip: View {
    let agent: AgentKind
    @Binding var model: String
    @State private var picking = false

    var body: some View {
        Button { picking = true } label: {
            Label(model.isEmpty ? "Default model" : (agent.modelPresets.first { $0.id == model }?.title ?? model), systemImage: "cpu")
                .font(.caption.weight(.medium)).lineLimit(1)
                .padding(.horizontal, 10).padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .glass(in: Capsule(), interactive: true)
        .sheet(isPresented: $picking) {
            NavigationStack {
                ModelPicker(agent: agent) { model = $0 }
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { picking = false } } }
            }
            .presentationDetents([.medium, .large])
        }
    }
}
