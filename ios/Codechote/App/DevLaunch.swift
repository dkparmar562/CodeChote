#if targetEnvironment(simulator)
import Foundation
import NIOCore
import NIOPosix

/// Launch options for the simulator, used to test without tapping:
///
///   -devSSH host:port:user:/path/to/key   connect straight away over SSH
///   -devRemote <port> -devToken T [...]   bundled UI against a server on this Mac (no SSH)
///   -devURL <url>                         open any URL in the workbench
///   -devTabs files,git,terminal,chat:claude,workbench,file:/abs/path   replace the open tabs
///   -devSelect <n>                        select the nth tab
extension AppModel {

    /// SwiftUI may create the model more than once at launch; connect only once.
    nonisolated(unsafe) private static var devConnectStarted = false

    private static func arg(_ name: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        return args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
    }

    func applyDevLaunchArguments() {
        // `-devHomeTab projects|agents|settings`: which home tab to start on.
        if let tab = Self.arg("-devHomeTab") { homeTab = tab == "projects" ? .projects : tab == "settings" ? .settings : .chats }
        if let url = Self.arg("-devURL").flatMap(URL.init(string:)) {
            let host = devHost(workbench: url)
            Task { await finishConnecting(host) }
        }

        if let remote = Self.arg("-devRemote").flatMap(Int.init), let root = SSHSession.bundledUIRoot {
            Task {
                await startDevRouter(remotePort: remote, token: Self.arg("-devToken") ?? "", commit: Self.arg("-devCommit") ?? "none",
                                     quality: Self.arg("-devQuality") ?? "none", productPath: Self.arg("-devProduct"), root: root)
            }
        }

        if let spec = Self.arg("-devSSH"), !Self.devConnectStarted {
            Self.devConnectStarted = true
            let parts = spec.split(separator: ":", maxSplits: 3).map(String.init)
            guard parts.count == 4, let port = Int(parts[1]), let key = try? String(contentsOfFile: parts[3], encoding: .utf8) else { return }
            var profile = ConnectionProfile()
            profile.id = UUID(uuidString: "00000000-0000-0000-0000-0000000DE001")!
            profile.name = "Dev host"
            profile.host = parts[0]
            profile.port = port
            profile.username = parts[2]
            profile.auth = .privateKey
            profile.secret = key
            Task { @MainActor in connect(profile) }
        }
    }

    /// `-devNewChat claude -devChatFolder /path`: open a new chat on the chats screen.
    /// `-devOpenChat <n>`: open the nth chat of the list once it has loaded.
    func applyDevChat(_ host: HostConnection) {
        if let name = Self.arg("-devNewChat"), let agent = AgentKind(rawValue: name) {
            chats.startNew(agent, hostID: host.id, folder: Self.arg("-devChatFolder") ?? host.home)
        }
        if let index = Self.arg("-devOpenChat").flatMap(Int.init) {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(4))
                await chats.refresh()
                if chats.sessions.indices.contains(index) { chats.open(chats.sessions[index]) }
            }
        }
    }

    func applyDevTabs(_ tabs: TabsModel) {
        if let root = Self.arg("-devRoot") { setRootFolder(root) }
        if let spec = Self.arg("-devTabs") {
            for tab in tabs.tabs { tabs.close(tab.id) }
            for item in spec.split(separator: ",").map(String.init) {
                switch item {
                case "files": tabs.open(.files)
                case "git": tabs.open(.git)
                case "agents": tabs.open(.agents)
                case "terminal": tabs.open(.terminal, detail: rootFolder)
                case "workbench": tabs.open(.workbench)
                case let s where s.hasPrefix("screen:"): tabs.open(.screen(port: Int(s.dropFirst(7)) ?? 5900))
                case let s where s.hasPrefix("browser:"): tabs.open(.browser(url: String(s.dropFirst(8))))
                case let s where s.hasPrefix("window:"): tabs.open(.window(folder: String(s.dropFirst(7))))
                case let s where s.hasPrefix("chat:"):
                    if let agent = AgentKind(rawValue: String(s.dropFirst(5))) { tabs.open(.chat(agent: agent, session: nil), detail: rootFolder) }
                case let s where s.hasPrefix("chatsession:"):
                    let parts = s.split(separator: ":").map(String.init)
                    if parts.count == 3, let agent = AgentKind(rawValue: parts[1]) { tabs.open(.chat(agent: agent, session: parts[2]), title: "Conversation", detail: rootFolder) }
                case let s where s.hasPrefix("file:"):
                    tabs.open(.file(path: String(s.dropFirst(5))))
                default: break
                }
            }
        }
        if ProcessInfo.processInfo.arguments.contains("-devWalk") {
            // Visit every tab in turn (so each gets a switcher picture), then open the switcher on the first.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(5))
                let ids = tabs.tabs.map(\.id)
                for id in ids { tabs.select(id); try? await Task.sleep(for: .seconds(2.5)) }
                if let first = ids.first { tabs.select(first); try? await Task.sleep(for: .seconds(1)) }
                tabs.showOverview = true
            }
        }
        if ProcessInfo.processInfo.arguments.contains("-devOverview") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { tabs.showOverview = true }
        }
        if ProcessInfo.processInfo.arguments.contains("-devNewTab") {
            DispatchQueue.main.asyncAfter(deadline: .now() + (Self.arg("-devNewTab").flatMap(Double.init) ?? 6)) { tabs.showNewTab = true }
        }
        if let home = Self.arg("-devHome") {
            let section: HomeSection = home == "agents" || home == "chats" ? .chats : home == "settings" ? .settings : .projects
            DispatchQueue.main.asyncAfter(deadline: .now() + 14) { self.goHome(section) }
        }
        if let index = Self.arg("-devSelect").flatMap(Int.init), tabs.tabs.indices.contains(index) {
            tabs.select(tabs.tabs[index].id)
        }
    }

    func startDevRouter(remotePort: Int, token: String, commit: String, quality: String, productPath: String?, root: URL) async {
        let product = productPath.flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let loop = MultiThreadedEventLoopGroup.singleton.next()
        let router = WorkbenchRouter(
            config: .init(token: token, commit: commit, quality: quality, product: product, bundleRoot: root),
            connector: { glue in
                try await ClientBootstrap(group: loop)
                    .channelInitializer { $0.pipeline.addHandler(glue) }
                    .connect(host: "127.0.0.1", port: remotePort).get()
            }
        )
        do {
            try await router.start(on: loop, preferredPort: 47_001)   // stable, like a real server
            devRouter = router
            let extra = Self.arg("-devQuery")
            let url = extra.flatMap { URL(string: router.url.absoluteString + "?" + $0) } ?? router.url
            let host = devHost(workbench: url)
            await finishConnecting(host)
        } catch {
            errorMessage = "Dev router failed: \(error)"
        }
    }
}
#endif
