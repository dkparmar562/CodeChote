import Observation
import SwiftUI
import UIKit

/// One screen of the workbench, as reported by the page.
struct Destination: Identifiable, Hashable {
    enum Group: String, CaseIterable {
        case core, sidebar, panel, agents, files

        var title: String {
            switch self {
            case .core: "Screens"
            case .sidebar: "Side bar"
            case .panel: "Panel"
            case .agents: "Agents & chat"
            case .files: "Open files"
            }
        }
    }

    let id: String
    let title: String
    let group: Group
    /// Codicon id when the container uses a built-in icon.
    let codicon: String?
    /// The container's own icon, rasterized by the page. Drawn as a template so it follows the tint.
    let image: UIImage?

    var systemSymbol: String { NavSymbols.symbol(for: self) }

    /// A label short enough for the bottom bar.
    var barTitle: String {
        let shortened: [String: String] = [
            "Source Control": "Git",
            "Run and Debug": "Debug",
            "Extensions": "Extensions",
            "Explorer": "Files",
        ]
        return shortened[title] ?? title
    }
}

/// Navigation state shared by the bottom bar, the full list, and the web bridge.
@MainActor
@Observable
final class NavModel {
    static let defaultPins = [
        "container:sidebar:workbench.view.explorer",
        "container:sidebar:workbench.view.search",
        "container:sidebar:workbench.view.scm",
        "editor",
        "container:panel:terminal",
    ]
    private static let pinsKey = "nav.pins.v1"

    var destinations: [Destination] = []
    var activeID: String?
    var showAll = false
    /// The workbench's own link to the server (separate from the SSH connection).
    var workbenchLink: String = "connected"
    /// Workbench theme colors, so the areas around the glass match the page.
    var topColor: Color?
    var bottomColor: Color?
    var pinnedIDs: [String] {
        didSet { UserDefaults.standard.set(pinnedIDs, forKey: Self.pinsKey) }
    }

    /// Asks the page to switch screens.
    var activateHandler: ((String) -> Void)?

    // MARK: File and folder picking

    /// Set while the page is waiting for the user to choose a file or folder.
    var pickRequest: PickRequest?
    /// Lists a directory on the host (over SSH, or the Mac in the simulator).
    var lister: ((String) async throws -> DirectoryListing)?
    /// Sends the choice (or nil on cancel) back to the page.
    var pickReply: ((String, String?) -> Void)?
    var lastPickPath: String?
    /// Paths from the page are VS Code remote paths (`/c:/Users`); the picker works in native form (`C:/Users`).
    var isWindows = false
    /// Folders opened on this host, most recent first. Persisted per server.
    var recentFolders: [String] = []
    var recentsKey = "recents.default" {
        didSet { recentFolders = UserDefaults.standard.stringArray(forKey: recentsKey) ?? [] }
    }
    var folderOpened: ((String) -> Void)?

    func addRecent(_ path: String) {
        recentFolders.removeAll { $0 == path }
        recentFolders.insert(path, at: 0)
        recentFolders = Array(recentFolders.prefix(12))
        UserDefaults.standard.set(recentFolders, forKey: recentsKey)
    }

    func finishPick(_ path: String?) {
        guard let request = pickRequest else { return }
        pickRequest = nil
        if let path, request.mode != .file { addRecent(path) }
        pickReply?(request.id, path)
    }

    init() {
        pinnedIDs = UserDefaults.standard.stringArray(forKey: Self.pinsKey) ?? Self.defaultPins
    }

    /// Pinned items that currently exist, in the user's order. An id whose container hasn't been
    /// contributed yet (extensions load late) stays pinned and appears once it does.
    var pinned: [Destination] {
        pinnedIDs.compactMap { id in destinations.first { $0.id == id } }
    }

    func isPinned(_ id: String) -> Bool { pinnedIDs.contains(id) }

    func togglePin(_ id: String) {
        if let i = pinnedIDs.firstIndex(of: id) { pinnedIDs.remove(at: i) } else { pinnedIDs.append(id) }
    }

    func movePins(from source: IndexSet, to destination: Int) {
        // Reorder only the pins that are showing; hidden ones keep their relative place at the end.
        var visible = pinned.map(\.id)
        visible.move(fromOffsets: source, toOffset: destination)
        pinnedIDs = visible + pinnedIDs.filter { !visible.contains($0) }
    }

    func activate(_ id: String) {
        activeID = id
        activateHandler?(id)
    }

    func destinations(in group: Destination.Group) -> [Destination] {
        destinations.filter { $0.group == group }
    }

    // MARK: Messages from the page

    func handle(_ message: [String: Any]) {
        switch message["nav"] as? String {
        case "destinations":
            let items = message["items"] as? [[String: Any]] ?? []
            destinations = items.compactMap(Self.parse)
        case "active":
            activeID = message["id"] as? String
        case "pick":
            guard let id = message["id"] as? String else { break }
            let mode = PickRequest.Mode(rawValue: message["mode"] as? String ?? "") ?? .any
            let fallback = mode == .file ? "Open File" : "Open Folder"
            pickRequest = PickRequest(id: id, mode: mode, title: (message["title"] as? String) ?? fallback, startPath: (message["path"] as? String).map { HostPath.fromWorkbench($0, windows: isWindows) })
        case "connection":
            workbenchLink = message["state"] as? String ?? "connected"
        case "theme":
            topColor = (message["top"] as? String).flatMap(Color.init(css:))
            bottomColor = (message["bottom"] as? String).flatMap(Color.init(css:))
        default:
            break
        }
    }

    private static func parse(_ item: [String: Any]) -> Destination? {
        guard let id = item["id"] as? String,
              let title = item["title"] as? String,
              let groupName = item["group"] as? String,
              let group = Destination.Group(rawValue: groupName) else { return nil }
        var image: UIImage?
        if let dataURL = item["icon"] as? String, let comma = dataURL.firstIndex(of: ","),
           let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])),
           let decoded = UIImage(data: data) {
            image = decoded.withRenderingMode(.alwaysTemplate)
        }
        return Destination(id: id, title: title, group: group, codicon: item["symbol"] as? String, image: image)
    }
}

enum NavSymbols {
    private static let byCodicon: [String: String] = [
        "files": "doc.on.doc",
        "search": "magnifyingglass",
        "source-control": "arrow.triangle.branch",
        "debug-alt": "ladybug",
        "run-view-icon": "ladybug",
        "extensions": "puzzlepiece.extension",
        "terminal": "terminal",
        "code": "chevron.left.forwardslash.chevron.right",
        "sparkle": "sparkles",
        "copilot": "sparkles",
        "comment-discussion": "bubble.left.and.bubble.right",
        "warning": "exclamationmark.triangle",
        "output": "text.alignleft",
        "debug-console": "apple.terminal",
        "list-flat": "list.bullet",
        "layers": "square.stack.3d.up",
        "database": "cylinder",
        "github": "chevron.left.forwardslash.chevron.right",
    ]

    static func symbol(for destination: Destination) -> String {
        if let codicon = destination.codicon, let symbol = byCodicon[codicon] { return symbol }

        let id = destination.id.lowercased()
        let title = destination.title.lowercased()
        if destination.group == .files { return "doc.text" }
        if id.contains("explorer") { return "doc.on.doc" }
        if id.contains("search") { return "magnifyingglass" }
        if id.contains("scm") || title.contains("source control") { return "arrow.triangle.branch" }
        if id.contains("terminal") { return "terminal" }
        if id.contains("chat") || destination.group == .agents { return "sparkles" }
        if id.contains("debug") || id.contains("run") { return "ladybug" }
        if id.contains("extensions") { return "puzzlepiece.extension" }
        if id.contains("markers") || title.contains("problems") { return "exclamationmark.triangle" }
        if id.contains("output") { return "text.alignleft" }
        return "square.grid.2x2"
    }
}

struct DestinationIcon: View {
    let destination: Destination

    var body: some View {
        if let image = destination.image {
            Image(uiImage: image).resizable().scaledToFit().padding(1)
        } else {
            Image(systemName: destination.systemSymbol).font(.system(size: 19)).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
