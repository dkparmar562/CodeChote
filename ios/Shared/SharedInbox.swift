import Foundation

/// Things sent to Codechote from other apps' share sheets. The Share extension writes them into the app group's
/// container; the app picks them up and starts a chat with them.
enum SharedInbox {
    static let groupID = "group.dev.codechote.app"

    struct Item: Codable {
        var id = UUID()
        var text: String
        /// File names inside the item's folder.
        var files: [String]
        var created = Date()
    }

    static var root: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)?.appendingPathComponent("Inbox", isDirectory: true)
    }

    static func folder(for id: UUID) -> URL? { root?.appendingPathComponent(id.uuidString, isDirectory: true) }

    /// Writes an item (called by the extension).
    static func save(text: String, files: [(name: String, data: Data)]) throws -> UUID {
        guard let root else { throw CocoaError(.fileNoSuchFile) }
        var item = Item(text: text, files: [])
        let folder = root.appendingPathComponent(item.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (index, file) in files.enumerated() {
            let name = file.name.isEmpty ? "file-\(index + 1)" : file.name
            try file.data.write(to: folder.appendingPathComponent(name))
            item.files.append(name)
        }
        try JSONEncoder().encode(item).write(to: folder.appendingPathComponent("item.json"))
        return item.id
    }

    /// Everything waiting, oldest first.
    static func pending() -> [Item] {
        guard let root, let folders = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        return folders.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("item.json")) else { return nil }
            return try? JSONDecoder().decode(Item.self, from: data)
        }
        .sorted { $0.created < $1.created }
    }

    static func remove(_ id: UUID) {
        if let folder = folder(for: id) { try? FileManager.default.removeItem(at: folder) }
    }
}
