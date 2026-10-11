import Observation
import SwiftUI

/// A saved command for a project: build, test, start the dev server.
struct RunShortcut: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var command: String
}

enum RunShortcutStore {
    private static func key(host: UUID, folder: String) -> String { "runs.\(host.uuidString)|\(folder)" }

    static func load(host: UUID, folder: String) -> [RunShortcut] {
        guard let data = UserDefaults.standard.data(forKey: key(host: host, folder: folder)) else { return [] }
        return (try? JSONDecoder().decode([RunShortcut].self, from: data)) ?? []
    }

    static func save(_ shortcuts: [RunShortcut], host: UUID, folder: String) {
        if let data = try? JSONEncoder().encode(shortcuts) { UserDefaults.standard.set(data, forKey: key(host: host, folder: folder)) }
    }

    /// Commands the project itself suggests: npm scripts, make targets, and the usual build and test commands.
    static func detect(in folder: String, on session: SSHSession) async -> [RunShortcut] {
        guard !session.os.isWindows else { return [] }
        let script = """
        cd \(shellQuote(folder)) || exit 0
        [ -f package.json ] && { echo '@@PKG'; head -c 200000 package.json; echo; echo '@@END'; }
        [ -f Makefile ] && grep -E '^[A-Za-z0-9_.-]+:' Makefile | grep -v '^\\.' | cut -d: -f1 | head -12 | sed 's/^/@@MAKE /'
        [ -f Package.swift ] && echo '@@HAS swift'
        [ -f Cargo.toml ] && echo '@@HAS cargo'
        [ -f go.mod ] && echo '@@HAS go'
        { [ -f pyproject.toml ] || [ -f pytest.ini ] || [ -d tests ]; } && [ -n "$(ls *.py tests/*.py 2>/dev/null | head -1)" ] && echo '@@HAS pytest'
        [ -f gradlew ] && echo '@@HAS gradle'
        """
        guard let result = try? await session.exec("sh -c \(shellQuote(script))") else { return [] }
        return parseDetection(result.stdout)
    }

    nonisolated static func parseDetection(_ output: String) -> [RunShortcut] {
        var found: [RunShortcut] = []
        if let start = output.range(of: "@@PKG\n"), let end = output.range(of: "\n@@END", range: start.upperBound..<output.endIndex),
           let package = try? JSONSerialization.jsonObject(with: Data(output[start.upperBound..<end.lowerBound].utf8)) as? [String: Any],
           let scripts = package["scripts"] as? [String: Any] {
            let runner = "npm run"
            let preferred = ["dev", "start", "build", "test", "lint", "typecheck"]
            let names = scripts.keys.sorted { (preferred.firstIndex(of: $0) ?? 99, $0) < (preferred.firstIndex(of: $1) ?? 99, $1) }
            for name in names.prefix(10) { found.append(RunShortcut(name: name, command: name == "test" || name == "start" ? "npm \(name)" : "\(runner) \(name)")) }
        }
        for line in output.split(separator: "\n") {
            if line.hasPrefix("@@MAKE ") { let target = String(line.dropFirst(7)); found.append(RunShortcut(name: "make \(target)", command: "make \(target)")) }
            switch line {
            case "@@HAS swift": found += [RunShortcut(name: "Build", command: "swift build"), RunShortcut(name: "Test", command: "swift test")]
            case "@@HAS cargo": found += [RunShortcut(name: "Build", command: "cargo build"), RunShortcut(name: "Test", command: "cargo test")]
            case "@@HAS go": found += [RunShortcut(name: "Build", command: "go build ./..."), RunShortcut(name: "Test", command: "go test ./...")]
            case "@@HAS pytest": found.append(RunShortcut(name: "Test", command: "python3 -m pytest"))
            case "@@HAS gradle": found += [RunShortcut(name: "Build", command: "./gradlew build"), RunShortcut(name: "Test", command: "./gradlew test")]
            default: break
            }
        }
        var seen = Set<String>()
        return found.filter { seen.insert($0.command).inserted }
    }
}

/// One run of a command on a host, with its output as it comes.
@MainActor
@Observable
final class RunJob: Identifiable {
    enum State: Equatable { case running, finished(Int), failed(String), stopped }

    let id = UUID()
    let name: String
    let command: String
    let folder: String
    let hostID: UUID
    let started = Date()
    private(set) var output = ""
    private(set) var state: State = .running
    private(set) var ended: Date?
    private var pid: String?
    private var task: Task<Void, Never>?
    private weak var session: SSHSession?
    /// Called when it ends.
    var onEnd: (() -> Void)?

    var notificationID: String { "run|\(id.uuidString)" }

    init(name: String, command: String, folder: String, hostID: UUID) {
        self.name = name
        self.command = command
        self.folder = folder
        self.hostID = hostID
    }

    func start(on session: SSHSession) {
        self.session = session
        guard !session.os.isWindows else { state = .failed("Running shortcuts on Windows hosts isn't supported yet."); return }
        // Its own process group, so Stop can end everything it started; the exit code comes last.
        let inner = "cd \(shellQuote(folder)) || exit 1; set -m; (\(command)) </dev/null 2>&1 & p=$!; echo \"@@PID $p\"; wait $p; echo \"@@EXIT $?\""
        let line = "\"${SHELL:-/bin/sh}\" -lc \(shellQuote(inner))"
        Notifier.shared.requestIfNeeded()
        task = Task { [weak self] in
            do {
                for try await text in session.execLines(line) {
                    guard let self else { return }
                    if text.hasPrefix("@@PID ") { self.pid = String(text.dropFirst(6)); continue }
                    if text.hasPrefix("@@EXIT "), let code = Int(text.dropFirst(7)) { self.finish(.finished(code)); continue }
                    self.append(text)
                }
                if self?.state == .running { self?.finish(.finished(0)) }
            } catch {
                self?.finish(.failed((error as? LocalizedError)?.errorDescription ?? "\(error)"))
            }
        }
    }

    private func append(_ text: String) {
        output += text + "\n"
        if output.count > 300_000 { output = String(output.suffix(250_000)) }
    }

    private func finish(_ final: State) {
        guard state == .running else { return }
        state = final
        ended = Date()
        onEnd?()
        let ok = final == .finished(0)
        let title = ok ? "\(name) finished" : (final == .stopped ? "\(name) stopped" : "\(name) failed")
        let tail = output.split(separator: "\n").suffix(2).joined(separator: "\n")
        Notifier.shared.needsAttention(chat: notificationID, title: title, body: tail.isEmpty ? command : tail)
    }

    func stop() {
        guard state == .running else { return }
        if let pid, let session { Task { _ = try? await session.exec("kill -TERM -- -\(pid) 2>/dev/null || kill -TERM \(pid)") } }
        task?.cancel()
        finish(.stopped)
    }

    var isRunning: Bool { state == .running }
}

/// Every run, so they keep going when their screen is closed.
@MainActor
@Observable
final class RunCenter {
    private(set) var jobs: [RunJob] = []
    /// The run on screen, so its own notification is not shown.
    var visibleJob: UUID?
    /// A run to show, from a tapped notification.
    var presented: RunJob?

    func run(_ shortcut: RunShortcut, folder: String, hostID: UUID, session: SSHSession) -> RunJob {
        let job = RunJob(name: shortcut.name, command: shortcut.command, folder: folder, hostID: hostID)
        jobs.insert(job, at: 0)
        if jobs.count > 30 { jobs.removeLast(jobs.count - 30) }
        job.onEnd = { [weak self] in self?.updateAwake() }
        job.start(on: session)
        updateAwake()
        return job
    }

    private func updateAwake() { ScreenAwake.set(.runs, jobs.contains(where: \.isRunning)) }

    func jobs(in folder: String, hostID: UUID) -> [RunJob] { jobs.filter { $0.folder == folder && $0.hostID == hostID } }

    func job(notificationID: String) -> RunJob? { jobs.first { $0.notificationID == notificationID } }
}

// MARK: - Screens

/// A project's shortcuts and runs.
struct RunsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let hostID: UUID
    let folder: String
    /// When opened from a chat: lets a failed run be handed to the agent.
    var askAgent: ((String) -> Void)?

    @State private var shortcuts: [RunShortcut] = []
    @State private var suggested: [RunShortcut] = []
    @State private var editing: RunShortcut?
    @State private var showing: RunJob?

    private var session: SSHSession? { model.connection(for: hostID)?.session }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if shortcuts.isEmpty { Text("No shortcuts yet. Add one, or pick from the suggestions below.").font(.footnote).foregroundStyle(.secondary) }
                    ForEach(shortcuts) { shortcut in
                        Button { run(shortcut) } label: { shortcutRow(shortcut, symbol: "play.circle.fill") }
                            .swipeActions {
                                Button("Delete", role: .destructive) { shortcuts.removeAll { $0.id == shortcut.id }; save() }
                                Button("Edit") { editing = shortcut }.tint(.blue)
                            }
                    }
                    Button { editing = RunShortcut(name: "", command: "") } label: { Label("Add Shortcut…", systemImage: "plus") }
                } header: { Text("Shortcuts") }

                let fresh = suggested.filter { s in !shortcuts.contains { $0.command == s.command } }
                if !fresh.isEmpty {
                    Section("Found in the project") {
                        ForEach(fresh) { suggestion in
                            HStack {
                                Button { run(suggestion) } label: { shortcutRow(suggestion, symbol: "play.circle") }
                                Button { shortcuts.append(suggestion); save() } label: { Image(systemName: "plus.circle") }
                                    .buttonStyle(.borderless).accessibilityLabel("Save \(suggestion.name)")
                            }
                        }
                    }
                }

                let runs = model.runs.jobs(in: folder, hostID: hostID)
                if !runs.isEmpty {
                    Section("Runs") {
                        ForEach(runs) { job in
                            Button { showing = job } label: { JobRow(job: job) }
                        }
                    }
                }
            }
            .navigationTitle("Run")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .task {
                shortcuts = RunShortcutStore.load(host: hostID, folder: folder)
                if let session { suggested = await RunShortcutStore.detect(in: folder, on: session) }
            }
            .sheet(item: $editing) { shortcut in
                ShortcutEditor(shortcut: shortcut) { saved in
                    if let index = shortcuts.firstIndex(where: { $0.id == saved.id }) { shortcuts[index] = saved } else { shortcuts.append(saved) }
                    save()
                }
            }
            .sheet(item: $showing) { job in RunOutputView(job: job, askAgent: askAgent) }
        }
    }

    private func shortcutRow(_ shortcut: RunShortcut, symbol: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.title3).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(shortcut.name).foregroundStyle(.primary)
                Text(shortcut.command).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private func run(_ shortcut: RunShortcut) {
        guard let session else { return }
        showing = model.runs.run(shortcut, folder: folder, hostID: hostID, session: session)
    }

    private func save() { RunShortcutStore.save(shortcuts, host: hostID, folder: folder) }
}

private struct JobRow: View {
    let job: RunJob

    var body: some View {
        HStack(spacing: 12) {
            switch job.state {
            case .running: ProgressView()
            case .finished(0): Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .stopped: Image(systemName: "stop.circle.fill").foregroundStyle(.secondary)
            default: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(job.name).foregroundStyle(.primary)
                Text(statusText).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var statusText: String {
        let duration = Int((job.ended ?? Date()).timeIntervalSince(job.started))
        switch job.state {
        case .running: return "Running · \(duration) s"
        case .finished(let code): return code == 0 ? "Passed · \(duration) s" : "Exit code \(code) · \(duration) s"
        case .failed(let message): return message
        case .stopped: return "Stopped"
        }
    }
}

private struct ShortcutEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var shortcut: RunShortcut
    let onSave: (RunShortcut) -> Void

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name, like Test", text: $shortcut.name)
                TextField("Command, like npm test", text: $shortcut.command, axis: .vertical)
                    .font(.body.monospaced()).textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            .navigationTitle(shortcut.name.isEmpty ? "New Shortcut" : shortcut.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(shortcut); dismiss() }
                        .disabled(shortcut.name.trimmingCharacters(in: .whitespaces).isEmpty || shortcut.command.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

/// A run's output as it comes, with Stop, and a way to hand a failure to the agent.
struct RunOutputView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let job: RunJob
    var askAgent: ((String) -> Void)?

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("$ " + job.command).font(.system(size: 12.5, weight: .semibold, design: .monospaced)).foregroundStyle(Color(white: 0.75))
                        Text(job.output.isEmpty ? (job.isRunning ? "…" : "(no output)") : job.output)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Color(white: 0.9))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(14)
                }
                .background(Color(red: 0.08, green: 0.09, blue: 0.11))
                .onChange(of: job.output.count) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            }
            .safeAreaInset(edge: .bottom) { footer }
            .navigationTitle(job.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    if job.isRunning { Button("Stop", role: .destructive) { job.stop() } }
                    else { Button { UIPasteboard.general.string = job.output } label: { Image(systemName: "doc.on.doc") } }
                }
            }
            .onAppear { model.runs.visibleJob = job.id }
            .onDisappear { if model.runs.visibleJob == job.id { model.runs.visibleJob = nil } }
        }
    }

    @ViewBuilder private var footer: some View {
        if case .finished(let code) = job.state, code != 0, let askAgent {
            Button {
                let tail = job.output.split(separator: "\n").suffix(80).joined(separator: "\n")
                askAgent("`\(job.command)` failed with exit code \(code). Here is the end of its output:\n\n```\n\(tail)\n```\n\nPlease find the cause and fix it.")
                dismiss()
            } label: {
                Label("Ask the Agent to Fix It", systemImage: "wand.and.stars").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding(12)
        } else if job.state != .running {
            Text(job.state == .finished(0) ? "Finished successfully" : (job.state == .stopped ? "Stopped" : "Finished"))
                .font(.footnote).foregroundStyle(.secondary).padding(10)
        }
    }
}
