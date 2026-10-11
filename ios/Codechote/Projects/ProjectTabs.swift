import Foundation
import Observation
import SwiftUI

/// What a tab shows. Files, Git and the VS Code workbench are one-per-host; the rest can repeat.
enum TabKind: Codable, Hashable {
    case workbench
    case window(folder: String)   // another VS Code window, on its own page
    case files
    case git
    case agents
    case terminal
    case browser(url: String)        // a page opened from the host's side
    case screen(port: Int)           // the host's desktop, through its VNC server on this port
    case agentTerminal(AgentKind)   // a provider's CLI in a terminal
    case chat(agent: AgentKind, session: String?)   // session nil: a new conversation
    case file(path: String)

    var isSingleton: Bool {
        switch self {
        case .workbench, .files, .git, .agents: true
        default: false
        }
    }

    var symbol: String {
        switch self {
        case .workbench, .window: "chevron.left.forwardslash.chevron.right"
        case .files: "folder"
        case .git: "arrow.triangle.branch"
        case .agents: "sparkles"
        case .terminal: "terminal"
        case .browser: "globe"
        case .screen: "display"
        case .agentTerminal(let agent): agent.symbol
        case .chat(let agent, _): agent.symbol
        case .file: "doc.text"
        }
    }

    var defaultTitle: String {
        switch self {
        case .workbench: "VS Code"
        case .window(let folder): (folder as NSString).lastPathComponent.isEmpty ? "VS Code" : (folder as NSString).lastPathComponent
        case .files: "Files"
        case .git: "Source Control"
        case .agents: "AI"
        case .terminal: "Terminal"
        case .browser: "Browser"
        case .screen: "Screen"
        case .agentTerminal(let agent): agent.title
        case .chat(let agent, _): agent.title
        case .file(let path): (path as NSString).lastPathComponent
        }
    }
}

struct AppTab: Identifiable, Hashable, Codable {
    var id = UUID()
    var kind: TabKind
    var title: String
    var detail: String?
}

/// The open tabs of one host, in order, with the selection. Remembered between launches.
@MainActor
@Observable
final class TabsModel {
    var tabs: [AppTab] = []
    var selectedID: UUID?
    var showOverview = false
    var showNewTab = false
    /// Latest picture of each tab, taken as you leave it. Shown on the switcher cards.
    var snapshots: [UUID: UIImage] = [:]
    /// Called just before the selection changes, while the outgoing tab is still on screen.
    var willChangeSelection: (() -> Void)?
    /// A line to show when a file opens (from a search result), by path. Taken by the editor.
    var pendingLines: [String: Int] = [:]

    private let storageKey: String

    init(profileKey: String) {
        storageKey = "tabs.\(profileKey)"
        restore()
    }

    var selected: AppTab? { tabs.first { $0.id == selectedID } }
    var selectedIndex: Int? { tabs.firstIndex { $0.id == selectedID } }

    @discardableResult
    func open(_ kind: TabKind, title: String? = nil, detail: String? = nil) -> AppTab {
        if kind.isSingleton, let existing = tabs.first(where: { $0.kind == kind }) {
            select(existing.id)
            return existing
        }
        // Reopening the same conversation or file selects it instead of adding a duplicate.
        var isSpecific = false
        switch kind {
        case .chat(_, let session): isSpecific = session != nil
        case .file, .window: isSpecific = true
        default: break
        }
        if isSpecific, let existing = tabs.first(where: { $0.kind == kind }) { select(existing.id); return existing }
        let tab = AppTab(kind: kind, title: title ?? kind.defaultTitle, detail: detail)
        tabs.append(tab)
        select(tab.id)
        return tab
    }

    func select(_ id: UUID) {
        if id != selectedID { willChangeSelection?() }
        selectedID = id
        showOverview = false
        showNewTab = false
        save()
    }

    func close(_ id: UUID) {
        if id == selectedID { willChangeSelection?() }
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: index)
        snapshots[id] = nil
        if selectedID == id { selectedID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id }
        save()
    }

    func update(_ id: UUID, title: String? = nil, detail: String? = nil) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        if let title { tabs[index].title = title }
        if let detail { tabs[index].detail = detail }
        save()
    }

    /// A chat that started as "new" becomes a specific conversation once the agent reports its id.
    func bind(_ id: UUID, toSession session: String) {
        guard let index = tabs.firstIndex(where: { $0.id == id }), case .chat(let agent, _) = tabs[index].kind else { return }
        tabs[index].kind = .chat(agent: agent, session: session)
        save()
    }

    /// Moves to the neighbouring tab. Does nothing at either end, like the iOS app switcher.
    @discardableResult
    func step(_ delta: Int) -> Bool {
        guard let index = selectedIndex, tabs.indices.contains(index + delta) else { return false }
        willChangeSelection?()
        selectedID = tabs[index + delta].id
        save()
        return true
    }

    // MARK: Persistence

    /// Projects of a host that have tabs saved, with how many.
    nonisolated static func savedProjects(profileKey: String) -> [(path: String, tabCount: Int)] {
        let prefix = "tabs.\(profileKey)|"
        return UserDefaults.standard.dictionaryRepresentation().compactMap { key, value in
            guard key.hasPrefix(prefix), let data = value as? Data, let stored = try? JSONDecoder().decode(Stored.self, from: data), !stored.tabs.isEmpty else { return nil }
            return (String(key.dropFirst(prefix.count)), stored.tabs.count)
        }
        .sorted { $0.path < $1.path }
    }

    /// Forgets a project's tabs.
    nonisolated static func forgetProject(profileKey: String, path: String) {
        UserDefaults.standard.removeObject(forKey: "tabs.\(profileKey)|\(path)")
    }

    private struct Stored: Codable { var tabs: [AppTab]; var selected: UUID? }

    private func save() {
        if let data = try? JSONEncoder().encode(Stored(tabs: tabs, selected: selectedID)) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    private func restore() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return }
        tabs = stored.tabs
        selectedID = stored.selected ?? stored.tabs.first?.id
    }
}
