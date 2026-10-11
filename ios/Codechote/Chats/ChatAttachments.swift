import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// A photo or file you attach to a message. It is copied to the host before the agent starts, and the message
/// tells the agent where to find it.
struct Attachment: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let data: Data
    let thumbnail: UIImage?

    /// A name that stays unique on the host and is safe in a path.
    var hostFileName: String {
        let safe = name.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" ? String($0) : "_" }.joined()
        return "\(id.uuidString.prefix(8).lowercased())-\(safe)"
    }
}

enum AttachmentLoader {
    static let maxFileBytes = 15_000_000

    /// A photo, scaled down (long side 2000 px) and re-encoded as JPEG: phone photos are large and agents don't need all of it.
    static func photo(from data: Data, name: String) -> Attachment? {
        guard let image = UIImage(data: data) else { return nil }
        let scaled = image.scaled(maxSide: 2000)
        guard let jpeg = scaled.jpegData(compressionQuality: 0.85) else { return nil }
        let base = (name as NSString).deletingPathExtension
        return Attachment(name: base + ".jpg", data: jpeg, thumbnail: scaled.scaled(maxSide: 160))
    }

    /// Any file from the Files app. Images are treated like photos.
    static func file(at url: URL) -> Attachment? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), data.count <= maxFileBytes else { return nil }
        if UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true, let photo = photo(from: data, name: url.lastPathComponent) { return photo }
        return Attachment(name: url.lastPathComponent, data: data, thumbnail: nil)
    }
}

extension UIImage {
    func scaled(maxSide: CGFloat) -> UIImage {
        let longest = max(size.width, size.height)
        guard longest > maxSide else { return self }
        let factor = maxSide / longest
        let target = CGSize(width: size.width * factor, height: size.height * factor)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in draw(in: CGRect(origin: .zero, size: target)) }
    }
}

/// The + next to the message box: photos from the library, or files.
struct AttachMenu: View {
    @Binding var attachments: [Attachment]
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var picked: [PhotosPickerItem] = []
    @State private var failed = false

    var body: some View {
        Menu {
            Button("Photo Library", systemImage: "photo.on.rectangle") { showPhotos = true }
            Button("Files", systemImage: "folder") { showFiles = true }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 44, height: 44)
                .glass(in: Circle(), interactive: true)
        }
        .accessibilityLabel("Attach")
        .photosPicker(isPresented: $showPhotos, selection: $picked, maxSelectionCount: 5, matching: .images)
        .onChange(of: picked) { _, items in
            guard !items.isEmpty else { return }
            Task {
                for (index, item) in items.enumerated() {
                    if let data = try? await item.loadTransferable(type: Data.self), let photo = AttachmentLoader.photo(from: data, name: "photo-\(index + 1)") {
                        attachments.append(photo)
                    } else {
                        failed = true
                    }
                }
                picked = []
            }
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            for url in urls {
                if let file = AttachmentLoader.file(at: url) { attachments.append(file) } else { failed = true }
            }
        }
        .alert("Couldn't attach that", isPresented: $failed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Files can be up to 15 MB, and photos must be in a format the phone can read.")
        }
    }
}

/// What is attached to the message being written.
struct AttachmentStrip: View {
    @Binding var attachments: [Attachment]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { item in
                    ZStack(alignment: .topTrailing) {
                        Group {
                            if let thumbnail = item.thumbnail {
                                Image(uiImage: thumbnail).resizable().scaledToFill()
                            } else {
                                VStack(spacing: 4) {
                                    Image(systemName: "doc").font(.title3)
                                    Text(item.name).font(.caption2).lineLimit(2).multilineTextAlignment(.center)
                                }
                                .padding(4)
                                .foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 64, height: 64)
                        .background(Color.secondary.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 12))

                        Button { attachments.removeAll { $0.id == item.id } } label: {
                            Image(systemName: "xmark.circle.fill").font(.system(size: 18)).symbolRenderingMode(.palette).foregroundStyle(.white, .black.opacity(0.65))
                        }
                        .buttonStyle(.plain)
                        .offset(x: 6, y: -6)
                        .accessibilityLabel("Remove \(item.name)")
                    }
                    .padding(.top, 6).padding(.trailing, 6)
                }
            }
            .padding(.horizontal, 12)
        }
    }
}
