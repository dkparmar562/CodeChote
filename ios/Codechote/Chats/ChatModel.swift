import Foundation
import Observation

/// One conversation with an agent: its history, the reply streaming in, and sending a new prompt.
@MainActor
@Observable
final class ChatModel {
    let agent: AgentKind
    private let host: SSHSession
    let folder: String

    private(set) var sessionID: String?
    private(set) var messages: [ChatMessage] = []
    private(set) var liveText = ""
    private(set) var isRunning = false { didSet { if isRunning != oldValue { onStateChange?() } } }
    /// Called when it starts or stops working, or starts or stops waiting on you (for the Live Activity).
    var onStateChange: (() -> Void)?
    private(set) var isLoading = false
    var errorText: String?
    private(set) var cliMissing = false
    var mode: PermissionMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "agent.mode.\(agent.rawValue)") }
    }

    /// The model passed to the agent; empty is its own default. Remembered per agent.
    var model: String {
        didSet { agent.selectedModel = model }
    }

    var onSessionStarted: ((String) -> Void)?
    var onFirstPrompt: ((String) -> Void)?
    /// Called when the agent stops and is waiting for you.
    var onTurnEnded: ((TurnOutcome) -> Void)?

    private var cli: String?
    private var task: Task<Void, Never>?
    private var localCounter = 0

    let hostID: UUID
    var hostSession: SSHSession { host }
    /// What the last turn cost (Claude Code reports it).
    private(set) var lastStats: TurnStats?
    /// The signature of the conversation file the shown messages came from, to notice changes made elsewhere.
    private var signature: String?
    private var watcher: Task<Void, Never>?

    init(agent: AgentKind, host: SSHSession, hostID: UUID = UUID(), folder: String, sessionID: String?) {
        self.agent = agent
        self.host = host
        self.hostID = hostID
        self.folder = folder
        self.sessionID = sessionID
        model = agent.selectedModel
        mode = UserDefaults.standard.string(forKey: "agent.mode.\(agent.rawValue)").flatMap(PermissionMode.init(rawValue:)) ?? .acceptEdits
    }

    /// Identifies the conversation across the app (notifications, the chats list).
    var chatID: String { sessionID.map { ChatKey.id(hostID: hostID, agent: agent, sessionID: $0) } ?? "draft|\(ObjectIdentifier(self).hashValue)" }

    /// The first thing you asked, as a title.
    var title: String {
        for message in messages where message.role == .user {
            for block in message.blocks { if case .text(let text) = block, !text.isEmpty { return String(text.prefix(80)) } }
        }
        return "New chat"
    }

    /// The agent is waiting on you: an approval, a question or a plan.
    var needsYou: Bool { !isRunning && (!pendingApprovals.isEmpty || openQuestions != nil || openPlan != nil) }

    /// Shows the saved copy at once, then brings it up to date from the host when the conversation file changed.
    func load() async {
        // Opening a chat can start this twice (from the list and from its screen): share one load.
        if let loading { await loading.value; return }
        let task = Task { await performLoad() }
        loading = task
        await task.value
        loading = nil
    }

    private var loading: Task<Void, Never>?

    /// The saved copy first (read off the main thread: long chats are megabytes), then the host's if it changed.
    private func performLoad() async {
        guard sessionID != nil else { return }
        if messages.isEmpty {
            isLoading = true
            let id = chatID
            let cached = await Task.detached(priority: .userInitiated) { ChatCache.transcript(id) }.value
            if messages.isEmpty, let cached {
                messages = cached.messages
                signature = cached.signature
            }
        }
        isLoading = messages.isEmpty
        await refreshFromHost(force: messages.isEmpty)
        isLoading = false
    }

    /// Re-reads the conversation if its file changed since it was last read (or always, with `force`).
    func refreshFromHost(force: Bool = false) async {
        guard let sessionID, !isRunning else { return }
        let adapter = adapter(for: agent)
        let current = await adapter.transcriptSignature(on: host, sessionID: sessionID)
        if !force, current == signature, current != nil || !messages.isEmpty { return }
        do {
            let fresh = try await adapter.loadTranscript(on: host, sessionID: sessionID)
            guard !isRunning, !fresh.isEmpty else { return }
            if fresh != messages { messages = fresh }
            signature = current
            let id = chatID
            Task.detached(priority: .utility) { ChatCache.saveTranscript(id, messages: fresh, signature: current) }
        } catch {
            if messages.isEmpty { errorText = "Couldn't load this conversation: \(describeError(error))" }
        }
    }

    /// While the chat is on screen, picks up turns made elsewhere (a terminal, VS Code) every few seconds.
    func startWatching() {
        watcher?.cancel()
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(6))
                guard let self, !Task.isCancelled else { return }
                await self.refreshFromHost()
            }
        }
    }

    func stopWatching() { watcher?.cancel(); watcher = nil }

    /// Sends your last message again.
    func retryLast() {
        guard !isRunning, let last = messages.last(where: { $0.role == .user }) else { return }
        // A message that never got an answer is replaced, not repeated.
        if messages.last?.id == last.id { messages.removeLast() }
        for block in last.blocks { if case .text(let text) = block { send(text); return } }
    }

    /// Tool calls the agent was blocked on, shown as approval cards until you answer them.
    private(set) var pendingApprovals: [PermissionRequest] = [] { didSet { if pendingApprovals.isEmpty != oldValue.isEmpty { onStateChange?() } } }
    /// Permission rules approved for the rest of this conversation.
    private var allowedRules: [String] = []

    /// Lets the agent make the blocked calls, then asks it to carry on. `remember` keeps the permission for this
    /// conversation; otherwise it applies to the next turn only.
    /// With several waiting, each answer is collected; the agent is told once all of them are answered.
    func approve(_ requests: [PermissionRequest], remember: Bool) {
        let rules = requests.map(\.rule)
        if remember { for rule in rules where !allowedRules.contains(rule) { allowedRules.append(rule) } }
        for rule in rules where !stagedRules.contains(rule) { stagedRules.append(rule) }
        pendingApprovals.removeAll { pending in requests.contains { $0.id == pending.id } }
        if pendingApprovals.isEmpty { sendApprovals() }
    }

    func decline(_ request: PermissionRequest) {
        pendingApprovals.removeAll { $0.id == request.id }
        if pendingApprovals.isEmpty, !stagedRules.isEmpty { sendApprovals() }
    }

    private var stagedRules: [String] = []

    private func sendApprovals() {
        let rules = stagedRules
        stagedRules = []
        guard !rules.isEmpty else { return }
        send("Approved. Please go ahead and retry what you were blocked on.", extraAllowed: rules)
    }

    // MARK: Questions and plans

    /// Questions or plans you dismissed without answering.
    private(set) var dismissed: Set<String> = [] { didSet { onStateChange?() } }

    /// The tool calls of the turn that just ended (everything after your last message).
    private var lastTurnToolCalls: [ToolCall] {
        var calls: [ToolCall] = []
        for message in messages.reversed() {
            if message.role == .user { break }
            for block in message.blocks { if case .tool(let call) = block { calls.append(call) } }
        }
        return calls
    }

    /// Questions the agent asked and is waiting on.
    var openQuestions: QuestionSet? {
        guard !isRunning else { return nil }
        for call in lastTurnToolCalls where call.name == "AskUserQuestion" && !dismissed.contains(call.id) {
            let questions = QuestionPrompt.parse(inputJSON: call.inputJSON)
            if !questions.isEmpty { return QuestionSet(id: call.id, questions: questions) }
        }
        return nil
    }

    /// A plan the agent wants approved before it starts.
    var openPlan: PlanPrompt? {
        guard !isRunning else { return nil }
        for call in lastTurnToolCalls where call.name == "ExitPlanMode" && !dismissed.contains(call.id) {
            if let plan = PlanPrompt.parse(id: call.id, inputJSON: call.inputJSON) { return plan }
        }
        return nil
    }

    func answer(_ set: QuestionSet, reply: String) {
        dismissed.insert(set.id)
        send(reply)
    }

    func dismiss(_ id: String) { dismissed.insert(id) }

    /// Approves a plan: the chat switches to editing and the agent is told to go ahead.
    func approvePlan(_ plan: PlanPrompt) {
        dismissed.insert(plan.id)
        mode = .acceptEdits
        send("The plan is approved. Go ahead and implement it.")
    }

    /// A message written while the agent was still busy. It is sent as soon as the current reply is done.
    struct QueuedMessage: Identifiable {
        let id = UUID()
        let text: String
        let attachments: [Attachment]
        let allowed: [String]
    }

    private(set) var queued: [QueuedMessage] = []
    /// Attachments are being copied to the host before the agent starts.
    private(set) var isUploading = false
    /// Counts runs, so a stopped run that finishes late cannot disturb the one that replaced it.
    private var runID = 0

    /// Sends a message. While the agent is busy it is queued instead (agents in headless mode take one message
    /// at a time) and goes out when the current reply ends or when you stop it.
    func send(_ prompt: String, attachments: [Attachment] = [], extraAllowed: [String] = []) {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty else { return }
        let item = QueuedMessage(text: text, attachments: attachments, allowed: extraAllowed)
        guard isRunning else { start(item); return }
        // Claude Code takes more messages while it works: send it straight away.
        if let job = currentJob, job.streamingInput, attachments.isEmpty, extraAllowed.isEmpty {
            localCounter += 1
            messages.append(ChatMessage(id: "local-\(localCounter)", role: .user, blocks: [.text(text)]))
            Task {
                do { try await job.appendInput(ClaudeAdapter.inputLine(text)) }
                catch { queued.append(item) }   // couldn't reach it: send when this turn ends
            }
            return
        }
        queued.append(item)
    }

    /// The run on the host, while one is going (Claude Code's takes messages mid-turn).
    private var currentJob: HostJob?

    func removeQueued(_ id: UUID) { queued.removeAll { $0.id == id } }

    private func start(_ item: QueuedMessage) {
        errorText = nil
        pendingApprovals = []
        var allowed = allowedRules
        for rule in item.allowed where !allowed.contains(rule) { allowed.append(rule) }
        if messages.isEmpty { onFirstPrompt?(item.text.isEmpty ? "Attachment" : item.text) }
        localCounter += 1
        let shown = ([item.text] + item.attachments.map { "📎 \($0.name)" }).filter { !$0.isEmpty }.joined(separator: "\n")
        messages.append(ChatMessage(id: "local-\(localCounter)", role: .user, blocks: [.text(shown)]))
        isRunning = true
        liveText = ""
        runID += 1
        let run = runID
        Notifier.shared.requestIfNeeded()
        Notifier.shared.turnStarted()

        task = Task {
            let adapter = adapter(for: agent)
            if cli == nil { cli = await adapter.locateCLI(on: host) }
            guard let cli else {
                cliMissing = true
                finishRun(run, notify: false)
                return
            }
            cliMissing = false
            var prompt = item.text
            if !item.attachments.isEmpty {
                isUploading = true
                do {
                    let paths = try await upload(item.attachments)
                    prompt += (prompt.isEmpty ? "" : "\n\n") + "Attached files (open them as needed):\n" + paths.map { "- \($0)" }.joined(separator: "\n")
                } catch {
                    errorText = "Couldn't send the attachment: \(describeError(error))"
                    isUploading = false
                    finishRun(run, notify: false)
                    return
                }
                isUploading = false
            }
            do {
                for try await event in adapter.send(prompt: prompt, sessionID: sessionID, folder: folder, mode: mode, model: model, allowedTools: allowed, on: host, cli: cli) {
                    handle(event)
                }
            } catch is CancellationError {
            } catch {
                errorText = describeError(error)
            }
            finishRun(run, notify: !Task.isCancelled)
        }
    }

    /// Ends a run. If you queued something meanwhile, that goes next and nothing is announced.
    private func finishRun(_ run: Int, notify: Bool) {
        guard run == runID, isRunning else { return }
        isRunning = false
        liveText = ""
        currentJob = nil
        Notifier.shared.turnEnded()
        // Keep the saved copy current, with the file's new signature so the next open needs no download.
        if sessionID != nil {
            let id = chatID, snapshot = messages
            Task {
                let current = await adapter(for: agent).transcriptSignature(on: host, sessionID: sessionID ?? "")
                signature = current
                await Task.detached(priority: .utility) { ChatCache.saveTranscript(id, messages: snapshot, signature: current) }.value
            }
        }
        if !queued.isEmpty { start(queued.removeFirst()); return }
        if notify { onTurnEnded?(pendingApprovals.isEmpty ? TurnOutcome.from(messages: messages, error: errorText) : .needsPermission) }
    }

    /// Copies attachments into the project so the agent can open them, and returns their paths on the host.
    private func upload(_ items: [Attachment]) async throws -> [String] {
        let directory = folder + "/.codechote-attachments"
        try await host.createFolder(directory)
        var paths: [String] = []
        for item in items {
            let path = directory + "/" + item.hostFileName
            try await host.writeFile(path, data: item.data)
            paths.append(path)
        }
        return paths
    }

    /// Stops the current reply. A message you queued goes out right away.
    func stop() {
        task?.cancel()
        finishRun(runID, notify: false)
    }

    func retryLocatingCLI() { cli = nil; cliMissing = false }

    private func handle(_ event: AgentEvent) {
        switch event {
        case .started(let id):
            if sessionID != id { sessionID = id; onSessionStarted?(id) }
        case .liveText(let fragment):
            liveText += fragment
        case .message(let message):
            if let index = messages.firstIndex(where: { $0.id == message.id }) { messages[index] = message } else { messages.append(message) }
            if message.role == .assistant, message.blocks.contains(where: { if case .text = $0 { true } else { false } }) { liveText = "" }
        case .toolResult(let toolID, let text, let isError):
            for m in messages.indices {
                for b in messages[m].blocks.indices {
                    if case .tool(var call) = messages[m].blocks[b], call.id == toolID {
                        call.result = text; call.isError = isError
                        messages[m].blocks[b] = .tool(call)
                    }
                }
            }
        case .finished(let summary):
            if let summary, !summary.isEmpty { errorText = summary }
        case .stats(let stats):
            lastStats = stats
        case .job(let job):
            currentJob = job
        case .permissionDenied(let requests):
            // Plans and questions have their own cards, so they are not listed as plain approvals.
            for request in requests where request.tool != "ExitPlanMode" && request.tool != "AskUserQuestion" && !pendingApprovals.contains(where: { $0.rule == request.rule }) {
                pendingApprovals.append(request)
            }
        }
    }
}
