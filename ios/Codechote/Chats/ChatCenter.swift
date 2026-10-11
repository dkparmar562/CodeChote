import Foundation
import Observation

/// Identifies a conversation on the chats screen: an agent's session on a host, or a new chat that has no
/// session yet (it gets one when the agent answers).
struct ChatKey: Hashable, Codable {
    let hostID: UUID
    let agent: AgentKind
    let folder: String
    var sessionID: String?
    var draftID = UUID()

    /// Stable across the move from draft to session, for navigation.
    static func == (a: ChatKey, b: ChatKey) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    var id: String { sessionID.map { ChatKey.id(hostID: hostID, agent: agent, sessionID: $0) } ?? "draft|\(draftID.uuidString)" }

    static func id(hostID: UUID, agent: AgentKind, sessionID: String) -> String { "\(hostID.uuidString)|\(agent.rawValue)|\(sessionID)" }

    init(session: AgentSession, fallbackFolder: String) {
        hostID = session.hostID ?? UUID()
        agent = session.agent
        folder = session.folder ?? fallbackFolder
        sessionID = session.id
    }

    init(draft agent: AgentKind, hostID: UUID, folder: String) {
        self.hostID = hostID
        self.agent = agent
        self.folder = folder
    }
}

/// Conversations saved on the phone so they show at once, before the host has answered: the list of chats per host,
/// and each transcript with the signature of the file it came from.
enum ChatCache {
    private struct Transcript: Codable { var signature: String?; var messages: [ChatMessage] }

    private static var directory: URL {
        let base = (try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)) ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("chats", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func file(_ name: String) -> URL {
        directory.appendingPathComponent(String(name.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" }) + ".json")
    }

    static func transcript(_ id: String) -> (signature: String?, messages: [ChatMessage])? {
        guard let data = try? Data(contentsOf: file("t-" + id)), let stored = try? JSONDecoder().decode(Transcript.self, from: data) else { return nil }
        return (stored.signature, stored.messages)
    }

    static func saveTranscript(_ id: String, messages: [ChatMessage], signature: String?) {
        guard !messages.isEmpty, let data = try? JSONEncoder().encode(Transcript(signature: signature, messages: Array(messages.suffix(400)))) else { return }
        try? data.write(to: file("t-" + id), options: .atomic)
    }

    static func removeTranscript(_ id: String) { try? FileManager.default.removeItem(at: file("t-" + id)) }

    /// Removes every saved transcript (the lists are kept, so the chats screen is not empty).
    static func clearAll() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent.hasPrefix("t-") { try? FileManager.default.removeItem(at: file) }
    }

    static func sessions(host: UUID) -> [AgentSession] {
        guard let data = try? Data(contentsOf: file("l-" + host.uuidString)) else { return [] }
        return (try? JSONDecoder().decode([AgentSession].self, from: data)) ?? []
    }

    static func saveSessions(_ sessions: [AgentSession], host: UUID) {
        if let data = try? JSONEncoder().encode(sessions) { try? data.write(to: file("l-" + host.uuidString), options: .atomic) }
    }
}

/// Every conversation the app knows about, and the live ones. Chats keep running here when you leave their screen,
/// so the list can show which are working and which need you, and a notification can open the right one.
@MainActor
@Observable
final class ChatCenter {
    weak var app: AppModel?

    /// The chats screen's navigation: the open conversation, if any.
    var path: [ChatKey] = []
    /// The conversation on screen, so its own notifications are not shown.
    var visibleChatID: String?

    private(set) var sessions: [AgentSession] = []
    private(set) var isRefreshing = false
    private var models: [String: ChatModel] = [:]
    private var keys: [String: ChatKey] = [:]

    private(set) var archived: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "chats.archived") ?? [])
    private(set) var titles: [String: String] = UserDefaults.standard.dictionary(forKey: "chats.titles") as? [String: String] ?? [:]

    enum Status { case idle, active, running, needsYou }

    init() {
        // Show what was there last time straight away, for every saved host.
        sessions = ProfileStore.load().flatMap { ChatCache.sessions(host: $0.id) }.sorted { $0.updated > $1.updated }
    }

    // MARK: Live conversations

    /// The model behind a conversation, created on first use. Nil while its host is not connected.
    func model(for key: ChatKey) -> ChatModel? {
        if let existing = models[key.id] {
            if existing.isRunning || existing.hostSession === app?.connection(for: key.hostID)?.session { return existing }
            models[key.id] = nil   // the host reconnected: start again on the new connection
        }
        guard let host = app?.connection(for: key.hostID), host.isConnected, let session = host.session else { return nil }
        let chat = ChatModel(agent: key.agent, host: session, hostID: key.hostID, folder: key.folder, sessionID: key.sessionID)
        let draftID = key.id
        chat.onSessionStarted = { [weak self, weak chat] sessionID in
            guard let self, let chat else { return }
            let id = ChatKey.id(hostID: key.hostID, agent: key.agent, sessionID: sessionID)
            self.models[id] = chat
            var saved = key
            saved.sessionID = sessionID
            self.keys[id] = saved
            self.keys[draftID] = saved
            if let title = self.titles[draftID] { self.titles[id] = title }
            self.insertLocally(chat, key: saved)
        }
        chat.onTurnEnded = { [weak self, weak chat] outcome in
            guard let self, let chat else { return }
            let id = chat.chatID
            Notifier.shared.needsAttention(chat: id, title: "\(key.agent.title): \(outcome.title)", body: "\(self.title(forChat: id, fallback: chat.title))\n\(outcome.body)")
            if let index = self.sessions.firstIndex(where: { self.chatID(of: $0) == id }) { self.sessions[index].updated = Date() }
        }
        chat.onStateChange = { [weak self, weak chat] in
            guard let self else { return }
            if let chat { lastChanged = chat }
            refreshActivity()
        }
        models[key.id] = chat
        keys[key.id] = key
        return chat
    }

    private weak var lastChanged: ChatModel?

    /// The Live Activity: how many chats are working and how many wait on you, and the latest of them.
    func refreshActivity() {
        var seen = Set<ObjectIdentifier>()
        let live = models.values.filter { seen.insert(ObjectIdentifier($0)).inserted }
        let working = live.filter(\.isRunning).count
        let waiting = live.filter(\.needsYou).count
        ScreenAwake.set(.chats, working > 0)
        #if DEBUG
        print("[activity] \(working) working, \(waiting) waiting")
        #endif
        let focus = lastChanged.flatMap { chat in (chat.isRunning || chat.needsYou) ? chat : nil }
            ?? live.first(where: \.needsYou) ?? live.first(where: \.isRunning)
        let detail: String
        if let focus {
            if focus.isRunning { detail = "\(focus.agent.title) is working…" }
            else if !focus.pendingApprovals.isEmpty { detail = "\(focus.agent.title) needs your approval" }
            else if focus.openPlan != nil { detail = "\(focus.agent.title) has a plan for you" }
            else { detail = "\(focus.agent.title) has a question" }
        } else { detail = "" }
        AgentLiveActivity.shared.update(working: working, waiting: waiting,
                                        headline: focus.map { title(forChat: $0.chatID, fallback: $0.title) } ?? "",
                                        detail: detail)
    }

    /// A conversation the agent has just started appears in the list without waiting for the next refresh.
    private func insertLocally(_ chat: ChatModel, key: ChatKey) {
        guard let sessionID = key.sessionID, !sessions.contains(where: { $0.id == sessionID && $0.hostID == key.hostID }) else { return }
        var session = AgentSession(agent: key.agent, id: sessionID, title: chat.title, updated: Date(), folder: key.folder)
        session.hostID = key.hostID
        session.hostName = app?.connection(for: key.hostID)?.name ?? ""
        sessions.insert(session, at: 0)
    }

    func chatID(of session: AgentSession) -> String {
        ChatKey.id(hostID: session.hostID ?? UUID(), agent: session.agent, sessionID: session.id)
    }

    func status(of session: AgentSession) -> Status {
        if let chat = models[chatID(of: session)] {
            if chat.needsYou { return .needsYou }
            if chat.isRunning { return .running }
        }
        return Date().timeIntervalSince(session.updated) < 120 ? .active : .idle
    }

    var runningCount: Int { Set(models.values.filter(\.isRunning).map { ObjectIdentifier($0) }).count }

    // MARK: Opening

    func open(_ session: AgentSession) {
        let key = ChatKey(session: session, fallbackFolder: app?.rootFolder ?? "")
        keys[key.id] = key
        // Start reading it now, so it's there by the time its screen has slid in.
        if let chat = model(for: key), chat.messages.isEmpty { Task { await chat.load() } }
        show(key)
    }

    /// Opens a new chat. `prompt` is put in its message box, ready for you to read and send.
    func startNew(_ agent: AgentKind, hostID: UUID, folder: String, prompt: String? = nil, attachments: [Attachment] = []) {
        UserDefaults.standard.set(agent.rawValue, forKey: "newchat.agent")
        UserDefaults.standard.set(hostID.uuidString, forKey: "newchat.host")
        UserDefaults.standard.set(folder, forKey: "newchat.folder")
        let key = ChatKey(draft: agent, hostID: hostID, folder: folder)
        if let prompt, !prompt.isEmpty { draftPrompts[key.id] = prompt }
        if !attachments.isEmpty { draftAttachments[key.id] = attachments }
        show(key)
    }

    private var draftPrompts: [String: String] = [:]
    private var draftAttachments: [String: [Attachment]] = [:]

    /// The text a new chat was opened with, once.
    func takeDraftPrompt(_ id: String) -> String? { draftPrompts.removeValue(forKey: id) }

    /// The files a new chat was opened with (from the share sheet), once.
    func takeDraftAttachments(_ id: String) -> [Attachment] { draftAttachments.removeValue(forKey: id) ?? [] }

    /// Opens a conversation by its id (from a notification).
    func open(chatID: String) {
        if let key = keys[chatID] { show(key); return }
        // After a cold start (the app was opened by the notification), find it in the saved list.
        if let session = sessions.first(where: { self.chatID(of: $0) == chatID }) { open(session) }
    }

    private func show(_ key: ChatKey) {
        app?.goHome(.chats)
        path = [key]
    }

    // MARK: Listing

    /// Asks every connected host for its conversations. Offline hosts keep what was saved last time.
    func refresh() async {
        guard let app, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let hosts = app.connectedHosts.compactMap { host in host.session.map { (host.id, host.name, $0) } }
        var fresh: [UUID: [AgentSession]] = [:]
        await withTaskGroup(of: (UUID, [AgentSession]).self) { group in
            for (hostID, hostName, session) in hosts {
                for agent in AgentKind.chatKinds {
                    group.addTask {
                        let found = await adapter(for: agent).listSessions(on: session, folder: nil).map { item in
                            var tagged = item
                            tagged.hostID = hostID
                            tagged.hostName = hostName
                            return tagged
                        }
                        return (hostID, found)
                    }
                }
            }
            for await (hostID, found) in group { fresh[hostID, default: []] += found }
        }
        for (hostID, list) in fresh { ChatCache.saveSessions(list, host: hostID) }
        let refreshed = Set(fresh.keys)
        var merged = sessions.filter { session in session.hostID.map { !refreshed.contains($0) } ?? false }
        merged += fresh.values.flatMap { $0 }
        // Keep conversations started here that the host does not list yet.
        for (id, chat) in models where chat.sessionID != nil && !merged.contains(where: { chatID(of: $0) == id }) {
            if let key = keys[id], let sessionID = key.sessionID {
                var session = AgentSession(agent: key.agent, id: sessionID, title: chat.title, updated: Date(), folder: key.folder)
                session.hostID = key.hostID
                merged.append(session)
            }
        }
        var seen = Set<String>()
        sessions = merged.sorted { $0.updated > $1.updated }.filter { seen.insert(chatID(of: $0)).inserted }
        for session in sessions { keys[chatID(of: session)] = ChatKey(session: session, fallbackFolder: "") }
    }

    // MARK: Archive, rename, delete

    private(set) var pinned: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "chats.pinned") ?? [])

    func isPinned(_ session: AgentSession) -> Bool { pinned.contains(chatID(of: session)) }

    /// Pinned chats stay at the top, under All and under their own project.
    func setPinned(_ session: AgentSession, _ value: Bool) {
        let id = chatID(of: session)
        if value { pinned.insert(id); archived.remove(id) } else { pinned.remove(id) }
        UserDefaults.standard.set(Array(pinned), forKey: "chats.pinned")
        UserDefaults.standard.set(Array(archived), forKey: "chats.archived")
    }

    func isArchived(_ session: AgentSession) -> Bool { archived.contains(chatID(of: session)) }

    func setArchived(_ session: AgentSession, _ value: Bool) {
        let id = chatID(of: session)
        if value { archived.insert(id) } else { archived.remove(id) }
        UserDefaults.standard.set(Array(archived), forKey: "chats.archived")
    }

    func title(of session: AgentSession) -> String { titles[chatID(of: session)] ?? session.title }

    func title(forChat id: String, fallback: String) -> String { titles[id] ?? fallback }

    /// The live chat for a key if there already is one; no side effects, so a screen can draw it at once.
    func existingModel(for key: ChatKey) -> ChatModel? { models[key.id] }

    /// A chat's title as the list shows it, for its screen before the conversation is read.
    func listedTitle(for key: ChatKey) -> String? { sessions.first { chatID(of: $0) == key.id }.map(title(of:)) }

    func rename(_ session: AgentSession, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        titles[chatID(of: session)] = trimmed.isEmpty ? nil : trimmed
        UserDefaults.standard.set(titles, forKey: "chats.titles")
    }

    func renameChat(id: String, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        titles[id] = trimmed.isEmpty ? nil : trimmed
        UserDefaults.standard.set(titles, forKey: "chats.titles")
    }

    /// Deletes a conversation on its host for good.
    func delete(_ session: AgentSession) async throws {
        guard let hostID = session.hostID, let host = app?.connection(for: hostID)?.session else { throw SessionError(message: "Connect to the host first.") }
        try await adapter(for: session.agent).deleteSession(on: host, sessionID: session.id)
        let id = chatID(of: session)
        sessions.removeAll { chatID(of: $0) == id }
        models[id] = nil
        archived.remove(id)
        ChatCache.removeTranscript(id)
        if let list = Optional(sessions.filter { $0.hostID == hostID }) { ChatCache.saveSessions(list, host: hostID) }
    }
}
