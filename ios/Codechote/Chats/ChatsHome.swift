import SwiftUI

/// The chats screen, the app's main one: every conversation with every agent on every host, newest first, with
/// the running ones and the ones waiting on you at the top. A conversation opens full screen; swipe from the left
/// edge to come back.
struct ChatsHome: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var agentFilter: AgentKind?
    @State private var projectFilter: String?
    @State private var showArchived = false
    @State private var showNewChat = false
    @State private var showSettings = false
    @State private var usage = UsageStore.shared
    /// Older groups the user opened.
    @State private var expanded: Set<String> = []
    @State private var renaming: AgentSession?
    @State private var newTitle = ""
    @State private var deleting: AgentSession?
    @State private var deleteError: String?

    private var chats: ChatCenter { model.chats }

    private var visible: [AgentSession] {
        chats.sessions.filter { session in
            chats.isArchived(session) == showArchived
            && (agentFilter == nil || session.agent == agentFilter)
            && (projectFilter == nil || session.folder == projectFilter)
            && (search.isEmpty || chats.title(of: session).localizedCaseInsensitiveContains(search) || (session.folder ?? "").localizedCaseInsensitiveContains(search))
        }
    }

    private var multipleHosts: Bool { Set(chats.sessions.compactMap(\.hostID)).count > 1 }

    var body: some View {
        @Bindable var center = model.chats
        NavigationStack(path: $center.path) {
            ScrollViewReader { proxy in
            List {
                filters
                content
                if usage.showUsage && !showArchived { UsageSection(usage: usage) { name in await usage.refresh(hosts: model.connectedHosts.filter { $0.name == name }, onlyThese: true) }.id("usage") }
            }
            #if targetEnvironment(simulator)
            .task {
                guard ProcessInfo.processInfo.arguments.contains("-devScrollToUsage") else { return }
                try? await Task.sleep(for: .seconds(14))
                withAnimation { proxy.scrollTo("usage", anchor: .bottom) }
            }
            #endif
            }
            .listStyle(.insetGrouped)
            .navigationTitle(showArchived ? "Archived" : "Chats")
            .searchable(text: $search, prompt: "Search chats")
            .refreshable { await chats.refresh() }
            .toolbar { toolbar }
            .navigationDestination(for: ChatKey.self) { key in ChatScreen(key: key) }
            .task {
                // Keep the list current while it is on screen.
                while !Task.isCancelled {
                    await chats.refresh()
                    try? await Task.sleep(for: .seconds(20))
                }
            }
            .task(id: "\(usage.showUsage)-\(usage.planLookup)-\(model.connectedHosts.map(\.id))") { if usage.showUsage { await usage.refresh(hosts: model.connectedHosts) } }
            .sheet(isPresented: $showNewChat) { NewChatSheet() }
            .sheet(isPresented: $showSettings) { AgentSettingsView(usage: usage) }
            .alert("Rename chat", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Title", text: $newTitle)
                Button("Save") { if let renaming { chats.rename(renaming, to: newTitle) }; renaming = nil }
                Button("Cancel", role: .cancel) { renaming = nil }
            }
            .confirmationDialog("Delete this chat?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    guard let session = deleting else { return }
                    Task { do { try await chats.delete(session) } catch { deleteError = AppModel.describe(error) } }
                    deleting = nil
                }
            } message: { Text("It is removed from the host too, and can't be brought back.") }
            .alert("Couldn't delete it", isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(deleteError ?? "") }
        }
    }

    // MARK: Parts

    /// Projects with chats, most recently used first, for the quick switcher.
    private var recentProjects: [String] {
        var seen = Set<String>(), result: [String] = []
        for session in chats.sessions where !chats.isArchived(session) {
            if let folder = session.folder, !folder.isEmpty, seen.insert(folder).inserted { result.append(folder) }
        }
        return result
    }

    @ViewBuilder private var filters: some View {
        let projects = recentProjects
        if projects.count > 1 || projectFilter != nil {
            Section {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            let names = ProjectPill.names(for: projects)
                            projectChip(nil, name: "All")
                            ForEach(projects, id: \.self) { projectChip($0, name: names[$0]).id($0) }
                        }
                        .padding(.horizontal, 16)
                    }
                    .onChange(of: projectFilter) { _, folder in if let folder { withAnimation { proxy.scrollTo(folder, anchor: .center) } } }
                }
                .listRowBackground(Color.clear).listRowInsets(EdgeInsets())
            }
        }
    }

    @ViewBuilder private var content: some View {
        if model.profiles.isEmpty && model.connectedHosts.isEmpty {
            ContentUnavailableView {
                Label("Add a host to start", systemImage: "server.rack")
            } description: {
                Text("Chats run on your own machines over SSH. Add one, then start a chat with any agent installed there.")
            } actions: {
                Button("Add a Host") { model.homeTab = .projects }.buttonStyle(.borderedProminent)
            }
            .listRowBackground(Color.clear)
        } else if visible.isEmpty {
            ContentUnavailableView {
                Label(showArchived ? "No archived chats" : "No chats yet", systemImage: "bubble.left.and.bubble.right")
            } description: {
                Text(showArchived ? "Archive a chat by swiping it to the left." : (model.connectedHosts.isEmpty ? "Connect to a host to see its conversations." : "Start one with the pencil button. Chats from the terminal or VS Code show up here too."))
            } actions: {
                if model.connectedHosts.isEmpty && !showArchived { Button("Connect a Host") { model.homeTab = .projects }.buttonStyle(.bordered) }
            }
            .listRowBackground(Color.clear)
        } else {
            let names = ProjectPill.names(for: recentProjects)
            let pinned = visible.filter { chats.isPinned($0) }
            if !pinned.isEmpty {
                Section("Pinned") { ForEach(pinned, id: \.key) { row($0, names) } }
            }
            let rest = visible.filter { !chats.isPinned($0) }
            let live = rest.filter { chats.status(of: $0) != .idle }
            if !live.isEmpty {
                Section("Now") { ForEach(live, id: \.key) { row($0, names) } }
            }
            ForEach(groups(rest.filter { chats.status(of: $0) == .idle }), id: \.title) { group in
                // Older groups start folded; searching shows everything.
                let collapsible = group.title == "Previous 7 Days" || group.title == "Older"
                let open = !collapsible || expanded.contains(group.title) || !search.isEmpty
                Section {
                    if open { ForEach(group.items, id: \.key) { row($0, names) } }
                } header: {
                    if collapsible {
                        Button {
                            withAnimation(.smooth(duration: 0.25)) {
                                if expanded.contains(group.title) { expanded.remove(group.title) } else { expanded.insert(group.title) }
                            }
                        } label: {
                            HStack {
                                Text(group.title)
                                Text("\(group.items.count)").foregroundStyle(.tertiary)
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).rotationEffect(.degrees(open ? 90 : 0))
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(group.title), \(group.items.count) chats, \(open ? "expanded" : "collapsed")")
                    } else {
                        Text(group.title)
                    }
                }
            }
        }
    }

    /// `names`: each project's name in the list (see ProjectPill.names).
    private func row(_ session: AgentSession, _ names: [String: String]) -> some View {
        Button { chats.open(session) } label: {
            ChatRow(session: session, title: chats.title(of: session), status: chats.status(of: session), showHost: multipleHosts,
                    online: model.connection(for: session.hostID ?? UUID())?.isConnected == true,
                    projectName: session.folder.flatMap { names[$0] })
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            Button(showArchived ? "Unarchive" : "Archive", systemImage: showArchived ? "tray.and.arrow.up" : "archivebox") { chats.setArchived(session, !showArchived) }
                .tint(.indigo)
            Button("Delete", systemImage: "trash", role: .destructive) { deleting = session }
        }
        .swipeActions(edge: .leading) {
            let isPinned = chats.isPinned(session)
            Button(isPinned ? "Unpin" : "Pin", systemImage: isPinned ? "pin.slash" : "pin") { chats.setPinned(session, !isPinned) }.tint(.orange)
            Button("Rename", systemImage: "pencil") { newTitle = chats.title(of: session); renaming = session }.tint(.blue)
        }
        .contextMenu {
            let isPinned = chats.isPinned(session)
            Button(isPinned ? "Unpin" : "Pin", systemImage: isPinned ? "pin.slash" : "pin") { chats.setPinned(session, !isPinned) }
            Button("Rename", systemImage: "pencil") { newTitle = chats.title(of: session); renaming = session }
            Button(showArchived ? "Unarchive" : "Archive", systemImage: "archivebox") { chats.setArchived(session, !showArchived) }
            Button("Delete", systemImage: "trash", role: .destructive) { deleting = session }
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarLeading) {
            Menu {
                Toggle("Archived Chats", systemImage: "archivebox", isOn: $showArchived)
                Picker("Agent", selection: $agentFilter) {
                    Text("All agents").tag(AgentKind?.none)
                    ForEach(AgentKind.chatKinds) { Text($0.title).tag(AgentKind?.some($0)) }
                }
            } label: {
                Image(systemName: agentFilter == nil && !showArchived ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
            }
            .accessibilityLabel("Filter")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button { showNewChat = true } label: { Image(systemName: "square.and.pencil") }
                .accessibilityLabel("New chat")
                .disabled(model.connectedHosts.isEmpty)
        }
    }

    private func projectChip(_ folder: String?, name: String?) -> some View {
        let selected = projectFilter == folder
        let tint = folder.map(ProjectPill.color(for:)) ?? Color.accentColor
        return Button { projectFilter = folder } label: {
            HStack(spacing: 6) {
                Image(systemName: folder == nil ? "square.stack" : "folder.fill").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(selected ? Color.white : (folder == nil ? Color.secondary : tint))
                Text(name ?? folder.map { ($0 as NSString).lastPathComponent } ?? "All").font(.subheadline.weight(selected ? .semibold : .regular)).lineLimit(1)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background(selected ? tint : Color.secondary.opacity(0.15), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    /// Today, Yesterday, Previous 7 Days, Older: as in Claude's list.
    private func groups(_ sessions: [AgentSession]) -> [(title: String, items: [AgentSession])] {
        let calendar = Calendar.current
        var today: [AgentSession] = [], yesterday: [AgentSession] = [], week: [AgentSession] = [], older: [AgentSession] = []
        for session in sessions {
            if calendar.isDateInToday(session.updated) { today.append(session) }
            else if calendar.isDateInYesterday(session.updated) { yesterday.append(session) }
            else if session.updated > Date().addingTimeInterval(-7 * 86400) { week.append(session) }
            else { older.append(session) }
        }
        return [("Today", today), ("Yesterday", yesterday), ("Previous 7 Days", week), ("Older", older)].filter { !$0.1.isEmpty }.map { ($0.0, $0.1) }
    }
}

struct ChatRow: View {
    let session: AgentSession
    let title: String
    let status: ChatCenter.Status
    let showHost: Bool
    let online: Bool
    /// The project's name as the list shows it (longer when two projects share a folder name).
    var projectName: String?

    var body: some View {
        HStack(spacing: 12) {
            AgentIcon(agent: session.agent)
                .overlay(alignment: .bottomTrailing) { badge }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.medium)).lineLimit(2).foregroundStyle(.primary)
                HStack(spacing: 6) {
                    if let folder = session.folder, !folder.isEmpty { ProjectPill(folder: folder, name: projectName) }
                    HStack(spacing: 4) {
                        statusText
                        Text(details).lineLimit(1)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .opacity(online ? 1 : 0.6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    /// "MacBook · 12m" (the project has its own pill)
    private var details: String {
        var parts: [String] = []
        if showHost, !session.hostName.isEmpty { parts.append(session.hostName) }
        parts.append(Self.age(session.updated))
        return parts.joined(separator: " · ")
    }

    static func age(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(seconds / 60)m"
        case ..<86400: return "\(seconds / 3600)h"
        case ..<(7 * 86400): return "\(seconds / 86400)d"
        default: return date.formatted(.dateTime.day().month(.abbreviated))
        }
    }

    @ViewBuilder private var badge: some View {
        switch status {
        case .needsYou: Circle().fill(Color.orange).frame(width: 11, height: 11).overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
        case .running: Circle().fill(Color.blue).frame(width: 11, height: 11).overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
        case .active: Circle().fill(Color.green).frame(width: 11, height: 11).overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
        case .idle: EmptyView()
        }
    }

    @ViewBuilder private var statusText: some View {
        switch status {
        case .needsYou: Text("Needs you ·").foregroundStyle(.orange).fontWeight(.semibold)
        case .running: Text("Working ·").foregroundStyle(.blue).fontWeight(.semibold)
        case .active: Text("Active ·").foregroundStyle(.green).fontWeight(.semibold)
        case .idle: EmptyView()
        }
    }
}

/// One conversation, full screen.
struct ChatScreen: View {
    @Environment(AppModel.self) private var model
    let key: ChatKey

    @State private var chat: ChatModel?
    @State private var input = ""
    @State private var renaming = false
    @State private var newTitle = ""
    @State private var showRuns = false
    @State private var showBrowser = false
    @State private var startAttachments: [Attachment] = []
    @State private var offlineMessages: [ChatMessage] = []
    @FocusState private var focused: Bool

    /// The chat to draw: the one this screen picked up, or the one opening it already started loading.
    private var live: ChatModel? { chat ?? model.chats.existingModel(for: key) }
    private var chatID: String { live?.chatID ?? key.id }
    private var fallbackTitle: String { model.chats.listedTitle(for: key) ?? live?.title ?? (key.sessionID == nil ? "New chat" : "Chat") }
    private var host: HostConnection? { model.connection(for: key.hostID) }

    var body: some View {
        Group {
            if let chat = live {
                ChatContent(chat: chat, agent: key.agent, input: $input, focused: $focused, folder: key.folder, showAllChats: nil, openTerminal: openTerminal, initialAttachments: startAttachments)
            } else if host?.isConnected == true {
                // The live chat is picked up straight away; drawing the saved copy for that moment only jumps.
                Color.clear
            } else {
                offline
            }
        }
        .navigationTitle(model.chats.title(forChat: chatID, fallback: fallbackTitle))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(model.chats.title(forChat: chatID, fallback: fallbackTitle)).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text("\(key.agent.title) · \((key.folder as NSString).lastPathComponent)\(host.map { " · \($0.name)" } ?? "")")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Rename", systemImage: "pencil") { newTitle = model.chats.title(forChat: chatID, fallback: chat?.title ?? ""); renaming = true }
                    Button("Run…", systemImage: "play.circle") { showRuns = true }
                    Button("Browser", systemImage: "safari") { showBrowser = true }.disabled(host?.session == nil)
                    if key.agent.command != nil { Button("Continue in Terminal", systemImage: "terminal", action: openTerminal) }
                    Button("Open Project", systemImage: "folder") { model.openProject(key.folder, on: key.hostID) }
                    if let id = chat?.sessionID { Button("Copy Session ID", systemImage: "doc.on.doc") { UIPasteboard.general.string = id } }
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await chat?.refreshFromHost(force: true) } }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .alert("Rename chat", isPresented: $renaming) {
            TextField("Title", text: $newTitle)
            Button("Save") { model.chats.renameChat(id: chatID, to: newTitle) }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showRuns) {
            RunsSheet(hostID: key.hostID, folder: key.folder) { prompt in chat?.send(prompt) }
        }
        .sheet(isPresented: $showBrowser) {
            if let session = host?.session { BrowserSheet(session: session, address: "") }
        }
        .task(id: host?.isConnected) { await attach() }
        // A new chat gets its real id when the agent starts it; keep its notifications quiet while it is on screen.
        .onChange(of: chat?.sessionID) { _, _ in if let chat { model.chats.visibleChatID = chat.chatID } }
        .onDisappear {
            chat?.stopWatching()
            if model.chats.visibleChatID == chatID { model.chats.visibleChatID = nil }
        }
    }

    /// Picks up the live conversation, or starts one, once the host is connected.
    private func attach() async {
        if model.connection(for: key.hostID) == nil, let profile = model.profiles.first(where: { $0.id == key.hostID }) {
            model.connect(profile)
        }
        guard chat == nil, let found = model.chats.model(for: key) else { return }
        if let prompt = model.chats.takeDraftPrompt(key.id) { input = prompt }
        startAttachments = model.chats.takeDraftAttachments(key.id)
        chat = found
        model.chats.visibleChatID = found.chatID
        found.startWatching()
        await found.load()
        #if targetEnvironment(simulator)
        // `-devChatSend "text"`: send a prompt shortly after a new chat opens (simulator tests).
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-devChatSend"), i + 1 < args.count, found.messages.isEmpty {
            try? await Task.sleep(for: .seconds(2))
            found.send(args[i + 1])
            // `-devFollowUp "text"`: send another message while that turn is still running.
            if let j = args.firstIndex(of: "-devFollowUp"), j + 1 < args.count {
                try? await Task.sleep(for: .seconds(1.5))
                found.send(args[j + 1])
            }
        }
        if args.contains("-devOpenRuns") { try? await Task.sleep(for: .seconds(2)); showRuns = true }
        // `-devTypeInput "/re"`: put text in the message box (to see suggestions).
        if let i = args.firstIndex(of: "-devTypeInput"), i + 1 < args.count {
            try? await Task.sleep(for: .seconds(1))
            input = args[i + 1]
        }
        // `-devPopAfter 1`: go back to the list that many seconds after sending (the chat keeps running).
        if let i = args.firstIndex(of: "-devPopAfter"), i + 1 < args.count, let delay = Double(args[i + 1]) {
            try? await Task.sleep(for: .seconds(delay))
            model.chats.path = []
        }
        // `-devAutoAnswer`: approve everything, answer questions with the first option, approve plans.
        if args.contains("-devAutoAnswer") {
            for _ in 0..<30 {
                try? await Task.sleep(for: .seconds(1))
                if !found.pendingApprovals.isEmpty { found.approve(found.pendingApprovals, remember: false); break }
                if let set = found.openQuestions { found.answer(set, reply: "\(set.questions[0].header): \(set.questions[0].options.first?.label ?? "")"); break }
                if let plan = found.openPlan { found.approvePlan(plan); break }
            }
        }
        #endif
    }

    private func openTerminal() {
        model.openProject(key.folder, on: key.hostID)
        model.tabs?.open(.agentTerminal(key.agent), title: key.agent.title, detail: key.folder)
    }

    /// The host is not connected: the saved copy, read-only, until it is.
    @ViewBuilder private var offline: some View {
        ScrollView {
            // Drawn as the live chat draws it, so nothing moves when the host connects and it takes over.
            VStack(alignment: .leading, spacing: 14) {
                let start = ChatItem.firstShown(of: offlineMessages, count: ChatItem.page)
                ForEach(ChatItem.items(from: offlineMessages[start...])) { ChatItemView(item: $0).equatable() }
            }
            .padding(.horizontal, 14).padding(.top, 8)
        }
        .id(offlineMessages.isEmpty)   // opens at the bottom once the saved copy is read
        .defaultScrollAnchor(.bottom)
        .task {
            let id = key.id
            offlineMessages = await Task.detached(priority: .userInitiated) { ChatCache.transcript(id)?.messages ?? [] }.value
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 10) {
                if host?.state == .connecting { ProgressView(); Text("Connecting to \(host?.name ?? "the host")…") }
                else if case .failed(let message) = host?.state { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange); Text(message).lineLimit(2) }
                else { Image(systemName: "bolt.horizontal.circle"); Text("Not connected") }
                Spacer()
                if host?.state != .connecting, let profile = model.profiles.first(where: { $0.id == key.hostID }) {
                    Button("Connect") { model.connect(profile) }.buttonStyle(.borderedProminent)
                }
            }
            .font(.footnote)
            .padding(12)
            .glass(in: RoundedRectangle(cornerRadius: 18))
            .padding(.horizontal, 12)
        }
    }
}

/// A chat tab saved from before chats moved out of the project tabs: offers to open it on the chats screen.
struct MovedToChats: View {
    @Environment(AppModel.self) private var model
    let tabs: TabsModel
    let tab: AppTab
    let chat: (agent: AgentKind, session: String?)?

    var body: some View {
        ContentUnavailableView {
            Label("Chats have their own screen", systemImage: "bubble.left.and.bubble.right")
        } description: {
            Text("Conversations now open full screen from Chats, where you can see which are running and which need you.")
        } actions: {
            Button(chat?.session != nil ? "Open This Chat" : "Open Chats") { open() }.buttonStyle(.borderedProminent)
            Button("Close Tab", role: .destructive) { tabs.close(tab.id) }.buttonStyle(.bordered)
        }
    }

    private func open() {
        guard let chat, let sessionID = chat.session, let hostID = model.activeHostID else { model.goHome(.chats); return }
        var session = AgentSession(agent: chat.agent, id: sessionID, title: tab.title, updated: Date(), folder: tab.detail ?? model.rootFolder)
        session.hostID = hostID
        model.chats.open(session)
    }
}

/// Starting a chat: which agent, and in which project.
struct NewChatSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var agent: AgentKind = AgentKind(rawValue: UserDefaults.standard.string(forKey: "newchat.agent") ?? "") ?? .claude
    @State private var hostID: UUID?
    @State private var folder: String?
    @State private var browsing: HostConnection?
    /// Something sent from another app's share sheet, to start the chat with.
    var shared: SharedInbox.Item?

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 10)]

    private var sharedAttachments: [Attachment] {
        guard let shared, let folder = SharedInbox.folder(for: shared.id) else { return [] }
        return shared.files.compactMap { name in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)) else { return nil }
            return FileKind.isImage(name) ? (AttachmentLoader.photo(from: data, name: name) ?? Attachment(name: name, data: data, thumbnail: nil)) : Attachment(name: name, data: data, thumbnail: nil)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if let shared {
                    Section("Shared with Codechote") {
                        if !shared.files.isEmpty { Label("\(shared.files.count) \(shared.files.count == 1 ? "file" : "files"): \(shared.files.joined(separator: ", "))", systemImage: "paperclip").lineLimit(2) }
                        if !shared.text.isEmpty { Text(shared.text).font(.footnote).lineLimit(3) }
                    }
                }
                Section("Agent") {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(AgentKind.chatKinds) { kind in
                            Button { agent = kind } label: {
                                VStack(spacing: 6) {
                                    AgentIcon(agent: kind, size: 36)
                                    Text(kind.title).font(.caption.weight(.medium)).lineLimit(1).minimumScaleFactor(0.8)
                                }
                                .frame(maxWidth: .infinity).padding(.vertical, 10)
                                .background(agent == kind ? Color.accentColor.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 12))
                                .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(agent == kind ? Color.accentColor : Color.secondary.opacity(0.2)) }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }

                ForEach(model.connectedHosts) { host in
                    Section(host.name) {
                        let projects = ProjectCache.paths(host: host.key).filter { $0 != host.home }
                        if projects.isEmpty { Text("No projects yet on this host.").font(.footnote).foregroundStyle(.secondary) }
                        ForEach(projects, id: \.self) { path in
                            Button { hostID = host.id; folder = path } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text((path as NSString).lastPathComponent).foregroundStyle(.primary)
                                        Text(path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                                    }
                                    Spacer()
                                    if hostID == host.id && folder == path { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                                }
                            }
                        }
                        Button { browsing = host } label: { Label("Choose Another Folder…", systemImage: "folder.badge.plus") }
                    }
                }
            }
            .navigationTitle("New chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") {
                        guard let hostID, let folder else { return }
                        let files = sharedAttachments, text = shared?.text
                        if let shared { SharedInbox.remove(shared.id) }
                        dismiss()
                        model.chats.startNew(agent, hostID: hostID, folder: folder, prompt: text, attachments: files)
                    }
                    .disabled(hostID == nil || folder == nil)
                }
            }
            .onAppear(perform: pickDefaults)
            .sheet(item: $browsing) { host in
                FolderPickerSheet(start: host.home, host: host) { path in
                    ProjectCache.touch(path, host: host.key)
                    hostID = host.id; folder = path
                }
            }
        }
        .presentationDetents([.large])
    }

    /// The last host and project used, else the open project, else the first project of the first host.
    private func pickDefaults() {
        let hosts = model.connectedHosts
        if let saved = UserDefaults.standard.string(forKey: "newchat.host").flatMap(UUID.init(uuidString:)), hosts.contains(where: { $0.id == saved }),
           let savedFolder = UserDefaults.standard.string(forKey: "newchat.folder") {
            hostID = saved; folder = savedFolder; return
        }
        if let active = model.active, let project = model.activeProjectPath { hostID = active.id; folder = project; return }
        if let first = hosts.first, let path = ProjectCache.paths(host: first.key).first(where: { $0 != first.home }) { hostID = first.id; folder = path }
    }
}

/// A project's name in its own colour, so chats from the same project are recognisable at a glance.
struct ProjectPill: View {
    let folder: String
    var name: String?

    var body: some View {
        let color = Self.color(for: folder)
        HStack(spacing: 4) {
            Image(systemName: "folder.fill").font(.system(size: 9, weight: .semibold))
            Text(name ?? (folder as NSString).lastPathComponent).font(.caption.weight(.semibold)).lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7).padding(.vertical, 2.5)
        .background(color.opacity(0.14), in: Capsule())
        .layoutPriority(1)
    }

    /// Each folder's shortest name that tells it apart from the others: "api", or "work/api" and
    /// "home/api" when two projects are both called api.
    nonisolated static func names(for folders: [String]) -> [String: String] {
        let unique = Array(Set(folders))
        var depth = Dictionary(uniqueKeysWithValues: unique.map { ($0, 1) })
        func label(_ folder: String) -> String {
            folder.split(separator: "/").suffix(depth[folder] ?? 1).joined(separator: "/")
        }
        for _ in 0..<6 {
            let clashing = Dictionary(grouping: unique, by: label).values.filter { $0.count > 1 }.joined()
            if clashing.isEmpty { break }
            for folder in clashing { depth[folder, default: 1] += 1 }
        }
        return Dictionary(uniqueKeysWithValues: unique.map { ($0, label($0)) })
    }

    private static let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .green, .indigo, .brown, .cyan, .red]

    /// The same colour for a project every time (string hashes change between launches, so this sums bytes).
    static func color(for folder: String) -> Color {
        var hash: UInt32 = 2166136261
        for byte in folder.utf8 { hash = (hash ^ UInt32(byte)) &* 16777619 }
        return palette[Int(hash % UInt32(palette.count))]
    }
}
