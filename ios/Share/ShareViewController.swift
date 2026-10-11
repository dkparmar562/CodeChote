import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// "Codechote" in the share sheet: collects the photos, files, text and links being shared, keeps them for the
/// app, and opens it to start a chat with them.
final class ShareViewController: UIViewController {
    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        model.onCancel = { [weak self] in self?.extensionContext?.cancelRequest(withError: CocoaError(.userCancelled)) }
        model.onDone = { [weak self] in self?.finish() }
        let host = UIHostingController(rootView: ShareView(model: model))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        Task { await model.load(extensionContext?.inputItems as? [NSExtensionItem] ?? []) }
    }

    private func finish() {
        openApp(URL(string: "codechote://inbox")!)
        extensionContext?.completeRequest(returningItems: nil)
    }

    /// Extensions can't open URLs directly; the application object found up the responder chain can. (If this
    /// stops working, the items still wait in the inbox and appear the next time the app is opened.)
    private func openApp(_ url: URL) {
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        guard let applicationClass = NSClassFromString("UIApplication") else { return }
        var responder: UIResponder? = self
        while let current = responder {
            if current.isKind(of: applicationClass), current.responds(to: selector) {
                typealias Open = @convention(c) (NSObject, Selector, NSURL, NSDictionary, Any?) -> Void
                let open = unsafeBitCast(current.method(for: selector), to: Open.self)
                open(current, selector, url as NSURL, NSDictionary(), nil)
                return
            }
            responder = current.next
        }
    }
}

@MainActor
final class ShareModel: ObservableObject {
    @Published var files: [(name: String, data: Data)] = []
    @Published var text = ""
    @Published var loading = true
    @Published var error: String?
    var onCancel: () -> Void = {}
    var onDone: () -> Void = {}

    func load(_ items: [NSExtensionItem]) async {
        var texts: [String] = []
        for item in items {
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier),
                   let data = try? await provider.loadData(UTType.image) {
                    let ext = provider.registeredContentTypes.first { $0.conforms(to: .image) }?.preferredFilenameExtension ?? "jpg"
                    files.append(((provider.suggestedName ?? "image-\(files.count + 1)") + "." + ext, data))
                } else if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) || provider.hasItemConformingToTypeIdentifier(UTType.data.identifier),
                          let file = try? await provider.loadFileCopy() {
                    files.append(file)
                } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier), let url = try? await provider.loadObject(URL.self) {
                    texts.append(url.absoluteString)
                } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier), let string = try? await provider.loadObject(String.self) {
                    texts.append(string)
                }
            }
        }
        text = texts.joined(separator: "\n")
        loading = false
    }

    func send() {
        do {
            _ = try SharedInbox.save(text: text, files: files)
            onDone()
        } catch {
            self.error = "Couldn't keep these for Codechote: \(error.localizedDescription)"
        }
    }
}

private extension NSItemProvider {
    func loadData(_ type: UTType) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            _ = loadDataRepresentation(for: type) { data, error in
                if let data { continuation.resume(returning: data) } else { continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
            }
        }
    }

    func loadFileCopy() async throws -> (name: String, data: Data) {
        try await withCheckedThrowingContinuation { continuation in
            _ = loadFileRepresentation(for: .data, openInPlace: false) { url, _, error in
                if let url, let data = try? Data(contentsOf: url) { continuation.resume(returning: (url.lastPathComponent, data)) }
                else { continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
            }
        }
    }

    func loadObject<T: _ObjectiveCBridgeable>(_ type: T.Type) async throws -> T where T._ObjectiveCType: NSItemProviderReading {
        try await withCheckedThrowingContinuation { continuation in
            _ = loadObject(ofClass: type) { value, error in
                if let value { continuation.resume(returning: value) } else { continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
            }
        }
    }
}

private struct ShareView: View {
    @ObservedObject var model: ShareModel

    var body: some View {
        NavigationStack {
            Form {
                if model.loading {
                    HStack { ProgressView(); Text("Getting it ready…").foregroundStyle(.secondary) }
                } else {
                    if !model.files.isEmpty {
                        Section("\(model.files.count) \(model.files.count == 1 ? "file" : "files")") {
                            ForEach(Array(model.files.enumerated()), id: \.offset) { _, file in
                                HStack {
                                    if let image = UIImage(data: file.data) {
                                        Image(uiImage: image).resizable().scaledToFill().frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 8))
                                    } else {
                                        Image(systemName: "doc").frame(width: 44, height: 44)
                                    }
                                    Text(file.name).lineLimit(1)
                                }
                            }
                        }
                    }
                    Section {
                        TextField("Message (optional)", text: $model.text, axis: .vertical).lineLimit(2...8)
                    } footer: {
                        Text("Codechote opens so you can pick the agent and project.")
                    }
                    if let error = model.error { Section { Text(error).foregroundStyle(.red) } }
                }
            }
            .navigationTitle("Send to Codechote")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { model.onCancel() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") { model.send() }.disabled(model.loading || (model.files.isEmpty && model.text.isEmpty))
                }
            }
        }
    }
}
