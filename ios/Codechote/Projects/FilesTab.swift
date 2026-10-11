import PhotosUI
import SwiftUI

/// Native file browser for the project folder on the host. Tap a folder to go in (swipe back to
/// return), tap a file to open it in an editor tab.
struct FilesTab: View {
    @Environment(AppModel.self) private var model
    let tabs: TabsModel
    @State private var path: [String] = []
    @State private var showFolderPicker = false

    var body: some View {
        NavigationStack(path: $path) {
            FolderView(folder: model.rootFolder, tabs: tabs, isRoot: true, showFolderPicker: $showFolderPicker)
                .navigationDestination(for: String.self) { folder in
                    FolderView(folder: folder, tabs: tabs, isRoot: false, showFolderPicker: $showFolderPicker)
                }
        }
        .onChange(of: model.rootFolder) { _, _ in path = [] }
        .sheet(isPresented: $showFolderPicker) { FolderPickerSheet(start: model.rootFolder) { chosen in model.setRootFolder(chosen) } }
    }
}

struct FolderView: View {
    @Environment(AppModel.self) private var model
    let folder: String
    let tabs: TabsModel
    let isRoot: Bool
    @Binding var showFolderPicker: Bool

    @State private var entries: [DirectoryEntry] = []
    @State private var isLoading = true
    @State private var errorText: String?
    @State private var filter = ""
    @State private var showHidden = false
    @State private var creating: Creating?
    @State private var newName = ""
    @State private var renaming: DirectoryEntry?
    @State private var deleting: DirectoryEntry?
    @State private var searching = false
    @State private var showPhotos = false
    @State private var showImporter = false
    @State private var pickedPhotos: [PhotosPickerItem] = []
    @State private var transfer: String?
    @State private var sharing: SharedFile?

    enum Creating: Identifiable { case file, folder; var id: Int { hashValue } }

    private var title: String { folder == "/" ? "/" : HostPath.lastComponent(folder) }

    private var visible: [DirectoryEntry] {
        entries.filter { (showHidden || !$0.name.hasPrefix(".")) && (filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter)) }
    }

    var body: some View {
        List {
            if let errorText {
                Label(errorText, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            if let transfer {
                HStack(spacing: 10) { ProgressView(); Text(transfer).foregroundStyle(.secondary) }
            }
            if isRoot {
                Section {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(folder).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2).truncationMode(.head)
                    }
                }
            }
            Section {
                ForEach(visible) { entry in
                    row(entry)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { deleting = entry } label: { Label("Delete", systemImage: "trash") }
                            Button { newName = entry.name; renaming = entry } label: { Label("Rename", systemImage: "pencil") }.tint(.orange)
                        }
                        .contextMenu {
                            Button("Copy Path", systemImage: "doc.on.doc") { UIPasteboard.general.string = join(entry.name) }
                            Button("Rename", systemImage: "pencil") { newName = entry.name; renaming = entry }
                            if !entry.isDirectory {
                                Button("Share…", systemImage: "square.and.arrow.up") { share(entry) }
                                Button("Ask an Agent…", systemImage: "bubble.left.and.text.bubble.right") { askAgent(about: join(entry.name)) }
                                Button("Open in VS Code", systemImage: "chevron.left.forwardslash.chevron.right") { openInWorkbench(join(entry.name)) }
                            }
                            Button("Delete", systemImage: "trash", role: .destructive) { deleting = entry }
                        }
                }
            } footer: {
                if !isLoading && visible.isEmpty { Text(filter.isEmpty ? "This folder is empty." : "No matches.") }
            }
        }
        .listStyle(.insetGrouped)
        .overlay { if isLoading && entries.isEmpty { ProgressView() } }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $filter, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Filter")
        .refreshable { await load() }
        .task(id: folder) { await load() }
        .toolbar {
            if isRoot {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showFolderPicker = true } label: { Label("Folder", systemImage: "folder.badge.gearshape") }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { searching = true } label: { Image(systemName: "text.magnifyingglass") }
                    .accessibilityLabel("Search in Files")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("New File", systemImage: "doc.badge.plus") { newName = ""; creating = .file }
                    Button("New Folder", systemImage: "folder.badge.plus") { newName = ""; creating = .folder }
                    Button("Upload Photos…", systemImage: "photo.on.rectangle") { showPhotos = true }
                    Button("Upload Files…", systemImage: "square.and.arrow.down") { showImporter = true }
                    Divider()
                    Toggle("Show Hidden Files", systemImage: "eye", isOn: $showHidden)
                    Button("Use as Project Folder", systemImage: "pin") { model.setRootFolder(folder) }
                    Button("Open Folder in VS Code", systemImage: "chevron.left.forwardslash.chevron.right") { openInWorkbench(folder, isFolder: true) }
                    Button("Open Terminal Here", systemImage: "terminal") { tabs.open(.terminal, detail: folder) }
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await load() } }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .navigationDestination(isPresented: $searching) { ProjectSearchView(folder: folder, tabs: tabs) }
        #if targetEnvironment(simulator)
        // `-devSearch text`: open Search in Files and search for it (simulator tests).
        .task { if isRoot, ProcessInfo.processInfo.arguments.contains("-devSearch") { try? await Task.sleep(for: .seconds(1)); searching = true } }
        #endif
        .photosPicker(isPresented: $showPhotos, selection: $pickedPhotos, maxSelectionCount: 20, matching: .images)
        .onChange(of: pickedPhotos) { _, items in
            guard !items.isEmpty else { return }
            pickedPhotos = []
            Task {
                var files: [(name: String, data: Data)] = []
                for (index, item) in items.enumerated() { if let file = await FileTransfer.photoFile(item, index: index) { files.append(file) } }
                await upload(files)
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            let files: [(name: String, data: Data)] = urls.compactMap { url in
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else { return nil }
                return (url.lastPathComponent, data)
            }
            Task { await upload(files) }
        }
        .sheet(item: $sharing) { ShareSheet(items: [$0.url]).presentationDetents([.medium, .large]) }
        .alert(creating == .file ? "New File" : "New Folder", isPresented: Binding(get: { creating != nil }, set: { if !$0 { creating = nil } })) {
            TextField("Name", text: $newName).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Create") { create() }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Rename") { rename() }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete “\(deleting?.name ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) { delete() }
        } message: {
            Text(deleting?.isDirectory == true ? "The folder and everything in it will be deleted from the host. This can't be undone." : "The file will be deleted from the host. This can't be undone.")
        }
    }

    @ViewBuilder
    private func row(_ entry: DirectoryEntry) -> some View {
        if entry.isDirectory {
            NavigationLink(value: join(entry.name)) {
                Label { Text(entry.name) } icon: { Image(systemName: "folder.fill").foregroundStyle(.blue) }
            }
        } else {
            Button { open(entry) } label: {
                Label { Text(entry.name).foregroundStyle(.primary) } icon: { Image(systemName: FileKind.symbol(for: entry.name, isDirectory: false)).foregroundStyle(.secondary) }
            }
            .buttonStyle(.plain)
        }
    }

    private func join(_ name: String) -> String { HostPath.join(folder, name, windows: model.isWindowsHost) }

    /// Copies files from the phone into this folder, keeping names unique.
    private func upload(_ files: [(name: String, data: Data)]) async {
        guard !files.isEmpty, let session = model.session else { return }
        var taken = Set(entries.map(\.name))
        errorText = nil
        var skipped: [String] = []
        for (index, file) in files.enumerated() {
            guard file.data.count <= FileTransfer.maxBytes else { skipped.append(file.name); continue }
            let name = FileTransfer.uniqueName(file.name, taken: taken)
            taken.insert(name)
            transfer = files.count == 1 ? "Uploading \(name)…" : "Uploading \(index + 1) of \(files.count)…"
            do {
                try await session.writeFile(join(name), data: file.data)
            } catch {
                errorText = "Couldn't upload \(name): \(describeError(error))"
                break
            }
        }
        transfer = nil
        if !skipped.isEmpty { errorText = "Skipped (bigger than 50 MB): " + skipped.joined(separator: ", ") }
        await load()
    }

    /// Copies a file to the phone and offers the share sheet.
    private func share(_ entry: DirectoryEntry) {
        guard let session = model.session else { return }
        transfer = "Copying \(entry.name) to the phone…"
        errorText = nil
        Task {
            defer { transfer = nil }
            do { sharing = SharedFile(url: try await FileTransfer.download(join(entry.name), on: session)) }
            catch { errorText = "Couldn't copy \(entry.name): \(describeError(error))" }
        }
    }

    /// A new chat about this file, with the agent you last used. The file is mentioned in the message, ready to finish.
    private func askAgent(about path: String) {
        guard let hostID = model.activeHostID else { return }
        let root = model.rootFolder
        let mention = path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : path
        let agent = AgentKind(rawValue: UserDefaults.standard.string(forKey: "newchat.agent") ?? "") ?? .claude
        model.chats.startNew(agent, hostID: hostID, folder: root, prompt: "@\(mention) ")
    }

    private func open(_ entry: DirectoryEntry) {
        tabs.open(.file(path: join(entry.name)), title: entry.name, detail: join(entry.name))
    }

    private func openInWorkbench(_ path: String, isFolder: Bool = false) {
        model.openInWorkbench(path, isFolder: isFolder, tabs: tabs)
    }

    private func load() async {
        isLoading = true
        errorText = nil
        do {
            entries = try await model.listDirectory(folder).entries
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? "Couldn't open this folder."
        }
        isLoading = false
    }

    private func create() {
        let kind = creating
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !name.contains("/"), let session = model.session else { return }
        Task {
            do {
                if kind == .folder { try await session.createFolder(join(name)) } else { try await session.createFile(join(name)) }
                await load()
                if kind == .file { tabs.open(.file(path: join(name)), title: name, detail: join(name)) }
            } catch { errorText = (error as? LocalizedError)?.errorDescription ?? "\(error)" }
        }
    }

    private func rename() {
        guard let entry = renaming, let session = model.session else { return }
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !name.contains("/"), name != entry.name else { return }
        Task {
            do { try await session.rename(join(entry.name), to: join(name)); await load() }
            catch { errorText = (error as? LocalizedError)?.errorDescription ?? "\(error)" }
        }
    }

    private func delete() {
        guard let entry = deleting, let session = model.session else { return }
        Task {
            do { try await session.delete(join(entry.name)); await load() }
            catch { errorText = (error as? LocalizedError)?.errorDescription ?? "\(error)" }
        }
    }
}

/// Browse the host and choose a folder to work in.
struct FolderPickerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let start: String
    /// The host to browse. Without one, the open project's host.
    var host: HostConnection?
    let onChoose: (String) -> Void
    @State private var nav = NavModel()

    var body: some View {
        Group {
            if let request = nav.pickRequest {
                ResourcePicker(nav: nav, request: request)
            } else {
                Color.clear
            }
        }
        .onAppear {
            nav.recentsKey = "recents.\(host?.key ?? model.profileKey)"
            nav.isWindows = host?.isWindows ?? model.isWindowsHost
            if let session = host?.session {
                nav.lister = { path in try await session.listDirectory(path) }
            } else {
                nav.lister = { path in try await model.listDirectory(path) }
            }
            nav.pickReply = { _, chosen in
                if let chosen { onChoose(chosen) }
                dismiss()
            }
            nav.pickRequest = PickRequest(id: "folder", mode: .folder, title: "Project folder", startPath: start)
        }
    }
}
