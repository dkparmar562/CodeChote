import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class AppModel {
    /// The VS Code workbench starts in the background; native tabs don't wait for it.
    enum WorkbenchState: Equatable {
        case idle
        case starting(String)
        case ready(URL)
        case failed(String)
    }

    enum ConnectionState: Equatable {
        case connected
        case reconnecting
        case failed(String)
    }

    var profiles: [ConnectionProfile] = ProfileStore.load()
    var errorMessage: String?
    var devRouter: AnyObject?

    /// Every host that is connected or connecting. Several can be live at once.
    private(set) var connections: [UUID: HostConnection] = [:]
    var connectedHosts: [HostConnection] {
        let order = Dictionary(uniqueKeysWithValues: profiles.enumerated().map { ($1.id, $0) })
        return connections.values.filter(\.isConnected).sorted { (order[$0.id] ?? .max, $0.name) < (order[$1.id] ?? .max, $1.name) }
    }
    func connection(for profileID: UUID) -> HostConnection? { connections[profileID] }

    /// The host whose project is open. The native screens (Files, Git, Terminal, chat) work on it.
    private(set) var activeHostID: UUID?
    var active: HostConnection? { activeHostID.flatMap { connections[$0] } }

    var tabs: TabsModel?
    /// Every conversation, and the live ones. Chats open from here, outside the project tabs.
    let chats = ChatCenter()
    /// Commands run from shortcuts, kept running when their screen is closed.
    let runs = RunCenter()
    /// Something sent from another app's share sheet, waiting to start a chat with.
    var sharedItem: SharedInbox.Item?

    /// Picks up what the Share extension left, oldest first.
    func checkInbox() {
        guard sharedItem == nil, let next = SharedInbox.pending().first else { return }
        // Very old items (a week) are dropped rather than offered.
        if next.created < Date().addingTimeInterval(-7 * 86400) { SharedInbox.remove(next.id); checkInbox(); return }
        goHome(.chats)
        sharedItem = next
    }
    var session: SSHSession? { active?.session }
    /// Identifies the active host for per-host saved state (tabs, cached projects).
    var profileKey: String { active?.key ?? "dev" }
    var home: String { active?.home ?? "" }
    var workbench: WorkbenchState {
        get { active?.workbench ?? .idle }
        set { active?.workbench = newValue }
    }
    var connection: ConnectionState {
        get { active?.link ?? .connected }
        set { active?.link = newValue }
    }
    var isWindowsHost: Bool { active?.isWindows ?? false }
    var recentFolders: [String] { ProjectCache.paths(host: profileKey) }

    /// The project folder the native screens work in (the open project).
    private(set) var rootFolder = ""
    /// The home screen (Projects, Chats, Settings) is shown on top while this is true.
    var showingHome = true
    /// Chats unless you pick another tab.
    var homeTab: HomeSection = .chats
    /// The project whose tabs are open. Each project of a host keeps its own tabs.
    private(set) var activeProject: String?
    var activeProjectPath: String? { activeProject }

    init() {
        Notifier.shared.isVisible = { [weak self] id in
            guard let tabs = self?.tabs else { return false }
            return tabs.selectedID == id && !tabs.showOverview && self?.showingHome == false
        }
        Notifier.shared.openTab = { [weak self] id in
            guard let tabs = self?.tabs, tabs.tabs.contains(where: { $0.id == id }) else { return }
            tabs.select(id)
        }
        Notifier.shared.isChatVisible = { [weak self] id in
            guard let self else { return false }
            if let job = runs.job(notificationID: id) { return runs.visibleJob == job.id }
            return showingHome && homeTab == .chats && chats.visibleChatID == id
        }
        Notifier.shared.openChat = { [weak self] id in
            guard let self else { return }
            if let job = runs.job(notificationID: id) { runs.presented = job } else { chats.open(chatID: id) }
        }
        chats.app = self
        #if targetEnvironment(simulator)
        applyDevLaunchArguments()
        #endif
        Task { @MainActor in self.connectAll() }
    }

    // MARK: Profiles

    func save(_ profile: ConnectionProfile) {
        if let i = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[i] = profile
        } else {
            profiles.append(profile)
        }
        ProfileStore.save(profiles)
    }

    func delete(_ profile: ConnectionProfile) {
        disconnect(profile.id)
        profiles.removeAll { $0.id == profile.id }
        Keychain.delete(profile.secretAccount)
        Keychain.delete(profile.secretAccount + ".pass")
        ProfileStore.save(profiles)
    }

    // MARK: Connecting

    /// Connects to every saved host that is not connected yet, without alerts: one that can't be reached shows
    /// as offline on the projects screen. Runs at launch and when the app comes back.
    func connectAll() {
        for profile in profiles {
            if let existing = connections[profile.id] {
                if existing.isConnected || existing.state == .connecting { continue }
            }
            connect(profile, quietly: true)
        }
    }

    /// Connects to a host (alongside any others), then optionally opens a project on it.
    func connect(_ profile: ConnectionProfile, thenOpen project: String? = nil, quietly: Bool = false) {
        if let existing = connections[profile.id] {
            if existing.isConnected { if let project { openProject(project, on: profile.id) }; return }
            if existing.state == .connecting { return }
        }
        errorMessage = nil
        let host = HostConnection(profile: profile)
        connections[profile.id] = host
        Task {
            let session = SSHSession(profile: profile)
            do {
                print("[app] ssh connecting to \(profile.host):\(profile.port)")
                try await session.connectSSH()
                print("[app] ssh connected")
                host.session = session
                await finishConnecting(host)
                startWorkbench(host)
                if let project { openProject(project, on: profile.id) }
            } catch {
                print("[app] connect failed: \(error)")
                await session.disconnect()
                host.state = .failed(Self.describe(error))
                if !quietly { errorMessage = "\(profile.displayName): \(Self.describe(error))" }
            }
        }
    }

    /// Installs (first time) and starts the VS Code server on the host, then opens the tunnel.
    /// Runs in the background; the workbench tab shows its progress.
    func startWorkbench(_ host: HostConnection) {
        guard let session = host.session else { return }
        host.workbench = .starting("Preparing VS Code…")
        Task {
            // A server that was just restarting can refuse the first try; give it a couple more.
            for attempt in 1...3 {
                do {
                    try await session.prepareServer { text in
                        Task { @MainActor in host.workbench = .starting(text) }
                    }
                    host.workbench = .starting("Opening tunnel…")
                    try await session.startFrontEnd()
                    print("[app] workbench ready")
                    host.workbench = .ready(restoring(session.workbenchURL, host: host))
                    return
                } catch {
                    print("[app] workbench attempt \(attempt) failed: \(error)")
                    if attempt == 3 { host.workbench = .failed(Self.describe(error)); return }
                    try? await Task.sleep(for: .seconds(Double(attempt) * 2))
                }
            }
        }
    }

    /// Retries the active host's VS Code server (the "Try again" button).
    func startWorkbench() { if let active { startWorkbench(active) } }

    /// Sets up per-host state once connected.
    func finishConnecting(_ host: HostConnection) async {
        host.link = .connected
        if let session = host.session {
            let result = session.os.isWindows ? try? await session.powershell("home") : try? await session.exec("printf %s \"$HOME\"")
            if let result, result.succeeded { host.home = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        host.state = .connected
        Task { await chats.refresh() }
        #if targetEnvironment(simulator)
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-devRoot") || args.contains("-devURL") {
            let root = UserDefaults.standard.string(forKey: "root.\(host.key)") ?? host.home
            openProject(root, on: host.id)
        }
        applyDevChat(host)
        #endif
    }

    /// A stand-in host for the simulator's no-SSH launch options.
    func devHost(workbench url: URL?) -> HostConnection {
        var profile = ConnectionProfile()
        profile.id = UUID(uuidString: "00000000-0000-0000-0000-0000000DE000")!
        profile.name = "Dev"
        let host = HostConnection(profile: profile)
        if let url { host.workbench = .ready(url) }
        connections[profile.id] = host
        return host
    }

    func disconnect(_ id: UUID) {
        guard let host = connections[id] else { return }
        connections[id] = nil
        let s = host.session
        if activeHostID == id {
            tabs = nil; activeProject = nil; activeHostID = nil
            showingHome = true
        }
        Task { await s?.disconnect() }
    }

    /// Called when the app returns to the foreground: every connected host is checked and revived.
    func didBecomeActive() {
        connectAll()   // hosts that dropped or never connected
        checkInbox()
        for host in connectedHosts {
            guard let session = host.session else { continue }
            host.link = .reconnecting
            Task {
                do {
                    let restarted = try await session.revive { _ in }
                    if restarted, case .ready = host.workbench { host.workbench = .ready(restoring(session.workbenchURL, host: host)) }
                    host.link = .connected
                } catch {
                    host.link = .failed("Connection lost: \(Self.describe(error))")
                }
            }
        }
    }

    /// Retry from the banner.
    func retryConnection() { didBecomeActive() }

    // MARK: Projects

    func setRootFolder(_ path: String) {
        guard !path.isEmpty else { return }
        rootFolder = path
        if let host = active {
            UserDefaults.standard.set(path, forKey: "root.\(host.key)")
            ProjectCache.touch(path, host: host.key)
        }
    }

    /// Opens a project on a host: its own tabs, with VS Code showing that folder. The host connects first if it
    /// is not connected. Opening the project that is already open just resumes it.
    func openProject(_ path: String, on hostID: UUID? = nil) {
        guard let id = hostID ?? activeHostID else { return }
        guard let host = connections[id], host.isConnected else {
            if let profile = profiles.first(where: { $0.id == id }) { connect(profile, thenOpen: path) }
            return
        }
        if id == activeHostID, path == activeProject, tabs != nil { showingHome = false; return }
        activeHostID = id
        setRootFolder(path)
        UserDefaults.standard.removeObject(forKey: "query.\(host.key)")
        let projectTabs = TabsModel(profileKey: "\(host.key)|\(path)")
        if projectTabs.tabs.isEmpty {
            projectTabs.open(.workbench)
            projectTabs.open(.files)
        }
        tabs = projectTabs
        activeProject = path
        showingHome = false
        if let session = host.session, case .ready = host.workbench { host.workbench = .ready(restoring(session.workbenchURL, host: host)) }
        #if targetEnvironment(simulator)
        applyDevTabs(projectTabs)
        #endif
    }

    /// Back to Hosts, Projects and Agents. The open project stays alive underneath.
    func goHome(_ section: HomeSection = .projects) {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        homeTab = section
        showingHome = true
    }

    /// Forgets a project of a host: its tabs and its place in the list.
    func removeProject(_ path: String, on hostID: UUID) {
        ProjectCache.remove(path, host: hostID.uuidString)
        if hostID == activeHostID, path == activeProject { tabs = nil; activeProject = nil }
    }

    func openChat(_ session: AgentSession) {
        guard let hostID = session.hostID else { return }
        openProject(session.folder ?? rootFolder, on: hostID)
        tabs?.open(.chat(agent: session.agent, session: session.id), title: String(session.title.prefix(36)), detail: session.folder ?? rootFolder)
    }

    func startChat(_ agent: AgentKind, in folder: String, on hostID: UUID) {
        openProject(folder, on: hostID)
        tabs?.launch(agent, folder: folder)
    }

    /// Shows a file or folder in the VS Code workbench tab.
    func openInWorkbench(_ path: String, isFolder: Bool, tabs: TabsModel) {
        let main = tabs.open(.workbench)
        guard case .ready(let base) = workbench, let handle = WorkbenchSnapshots.shared.bridge(for: main.id) else { return }
        if isFolder {
            setRootFolder(path)
            var parts = URLComponents(url: base, resolvingAgainstBaseURL: false)
            parts?.queryItems = [URLQueryItem(name: "folder", value: HostPath.toWorkbench(path, windows: isWindowsHost))]
            if let url = parts?.url { handle.webView?.load(URLRequest(url: url)) }
        } else if let host = handle.webView?.url?.host, let port = handle.webView?.url?.port {
            handle.nav.activate("file:vscode-remote://\(host):\(port)\(HostPath.toWorkbench(path, windows: isWindowsHost))")
        }
    }

    // MARK: Remembering what was open

    private var queryKey: String { "query.\(profileKey)" }

    /// Reopens the folder or workspace that was open last time: the workbench reads it from the
    /// page URL's query (`?folder=/path`).
    func restoring(_ url: URL, host: HostConnection? = nil) -> URL {
        let host = host ?? active
        let saved = UserDefaults.standard.string(forKey: "query.\(host?.key ?? profileKey)")
        let folder = HostPath.toWorkbench(rootFolder, windows: host?.isWindows ?? isWindowsHost)
        let query = (saved?.isEmpty == false) ? saved! : (rootFolder.isEmpty ? nil : "folder=" + (folder.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? folder))
        guard let query, let restored = URL(string: url.absoluteString + "?" + query) else { return url }
        return restored
    }

    /// Called whenever the page navigates; remembers which folder it is showing.
    func pageNavigated(_ url: URL?) -> String? {
        guard let url, let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        guard let item = items.first(where: { $0.name == "folder" || $0.name == "workspace" }), let value = item.value else {
            if items.contains(where: { $0.name == "ew" }) { UserDefaults.standard.removeObject(forKey: queryKey) }
            return nil
        }
        let encoded = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
        UserDefaults.standard.set("\(item.name)=\(encoded)", forKey: queryKey)
        let native = HostPath.fromWorkbench(value, windows: isWindowsHost)
        return item.name == "folder" ? native : nil
    }

    // MARK: Browsing the host

    func listDirectory(_ path: String) async throws -> DirectoryListing {
        if let session { return try await session.listDirectory(path) }
        #if targetEnvironment(simulator)
        return try Self.listLocalDirectory(path)   // dev mode: browse this Mac
        #else
        throw SessionError(message: "Not connected")
        #endif
    }

    #if targetEnvironment(simulator)
    private static func listLocalDirectory(_ path: String) throws -> DirectoryListing {
        let base = path.isEmpty ? ProcessInfo.processInfo.environment["SIMULATOR_HOST_HOME"] ?? NSHomeDirectory() : path
        let names = try FileManager.default.contentsOfDirectory(atPath: base)
        let entries = names.map { name -> DirectoryEntry in
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: (base as NSString).appendingPathComponent(name), isDirectory: &isDir)
            return DirectoryEntry(name: name, isDirectory: isDir.boolValue)
        }
        .sorted { ($0.isDirectory ? 0 : 1, $0.name.lowercased()) < ($1.isDirectory ? 0 : 1, $1.name.lowercased()) }
        return DirectoryListing(path: base, entries: entries)
    }
    #endif

    static func describe(_ error: Error) -> String { describeError(error) }
}
