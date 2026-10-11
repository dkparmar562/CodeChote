import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Moving files between the phone and the host: uploads into a folder, and sharing a host file from the phone.
enum FileTransfer {
    /// Biggest file that is copied either way. Transfers go over SSH commands, so very large files are slow.
    static let maxBytes = 50_000_000

    /// `name`, or "name 2.ext", "name 3.ext"… when that is taken.
    nonisolated static func uniqueName(_ name: String, taken: Set<String>) -> String {
        guard taken.contains(name) else { return name }
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var number = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)"
            if !taken.contains(candidate) { return candidate }
            number += 1
        }
    }

    /// A photo from the library as a file: PNG and JPEG are kept as they are, other formats (HEIC) become JPEG.
    static func photoFile(_ item: PhotosPickerItem, index: Int) async -> (name: String, data: Data)? {
        guard let data = try? await item.loadTransferable(type: Data.self) else { return nil }
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)).replacingOccurrences(of: ":", with: "")
        let base = "photo-\(stamp)" + (index > 0 ? "-\(index + 1)" : "")
        let type = item.supportedContentTypes.first
        if let type, type.conforms(to: .png) { return (base + ".png", data) }
        if let type, type.conforms(to: .jpeg) { return (base + ".jpg", data) }
        guard let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.9) else { return nil }
        return (base + ".jpg", jpeg)
    }

    /// Copies a host file to the phone's temporary folder, ready for the share sheet.
    static func download(_ path: String, on session: SSHSession) async throws -> URL {
        let (data, truncated) = try await session.readFile(path, limit: maxBytes)
        guard !truncated else { throw HostFileError(message: "This file is bigger than 50 MB, too big to copy to the phone this way.") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("shared-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent((path as NSString).lastPathComponent)
        try data.write(to: url)
        return url
    }
}

/// A file ready to share.
struct SharedFile: Identifiable {
    let url: URL
    var id: URL { url }
}

/// The system share sheet (Save to Files, AirDrop, Messages, …).
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
