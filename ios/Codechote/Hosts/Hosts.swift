import Foundation
import Observation

/// One host the app is connected to, or connecting to. Several can be connected at once.
@MainActor
@Observable
final class HostConnection: Identifiable {
    enum State: Equatable {
        case connecting
        case connected
        case failed(String)
    }

    let profile: ConnectionProfile
    var id: UUID { profile.id }
    /// Identifies this host in per-host saved state (tabs, cached projects).
    var key: String { profile.id.uuidString }
    var name: String { profile.displayName }

    var state: State = .connecting
    var session: SSHSession?
    var home = ""
    /// This host's VS Code server, started in the background after connecting.
    var workbench: AppModel.WorkbenchState = .idle
    /// The state of the link after the app returns from the background.
    var link: AppModel.ConnectionState = .connected

    var isConnected: Bool { if case .connected = state { true } else { false } }
    var isWindows: Bool { session?.os.isWindows ?? false }

    init(profile: ConnectionProfile) { self.profile = profile }

    /// Git projects near the home folder. Only on request: the app never scans a host by itself.
    func findProjects() async -> [String] {
        guard let session, !session.os.isWindows else { return [] }
        let script = #"find "$HOME" -maxdepth 4 -name .git -type d -not -path "$HOME/Library/*" -not -path '*/node_modules/*' -not -path '*/.*/*' 2>/dev/null | head -60 | sed 's#/\.git$##' | sort"#
        guard let result = try? await session.exec("sh -c \(shellQuote(script))"), result.succeeded else { return [] }
        return result.stdout.split(whereSeparator: \.isNewline).map(String.init)
    }
}

/// The projects you have opened on each host, kept on the phone so they show even while the host is not connected.
enum ProjectCache {
    private static func key(_ host: String) -> String { "recents.\(host)" }

    static func paths(host: String) -> [String] {
        var seen = Set<String>(), result: [String] = []
        let saved = TabsModel.savedProjects(profileKey: host).map(\.path)
        for path in (UserDefaults.standard.stringArray(forKey: key(host)) ?? []) + saved where seen.insert(path).inserted { result.append(path) }
        return result
    }

    /// Moves a project to the front, adding it if new.
    static func touch(_ path: String, host: String) {
        var list = UserDefaults.standard.stringArray(forKey: key(host)) ?? []
        list.removeAll { $0 == path }
        list.insert(path, at: 0)
        UserDefaults.standard.set(Array(list.prefix(60)), forKey: key(host))
    }

    static func remove(_ path: String, host: String) {
        var list = UserDefaults.standard.stringArray(forKey: key(host)) ?? []
        list.removeAll { $0 == path }
        UserDefaults.standard.set(list, forKey: key(host))
        TabsModel.forgetProject(profileKey: host, path: path)
    }
}
