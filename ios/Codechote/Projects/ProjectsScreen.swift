import SwiftUI

/// A project on a host, for sheets that work on one.
struct ProjectRef: Identifiable, Hashable {
    let hostID: UUID
    let folder: String
    var id: String { "\(hostID.uuidString)|\(folder)" }
}

/// Every host and its projects. Projects are remembered on the phone, so they stay listed while a host is not
/// connected (opening one connects first). Nothing is scanned unless you ask.
struct ProjectsScreen: View {
    @Environment(AppModel.self) private var model
    @State private var browsing: HostConnection?
    @State private var finding: HostConnection?
    @State private var editing: ConnectionProfile?
    @State private var deletingHost: ConnectionProfile?
    @State private var newProject = false
    @State private var running: ProjectRef?
    @State private var pullRequests: ProjectRef?

    var body: some View {
        NavigationStack {
            Group {
                if model.profiles.isEmpty {
                    ContentUnavailableView {
                        Label("No hosts yet", systemImage: "server.rack")
                    } description: {
                        Text("Add the machine you work on: a Mac, a Linux box or a Windows PC with SSH. Its projects and agents show up here.")
                    } actions: {
                        Button("Add Host") { editing = ConnectionProfile() }.buttonStyle(.borderedProminent)
                    }
                } else {
                    list
                }
            }
            .navigationTitle("Projects")
            .toolbar {
                if model.tabs != nil {
                    ToolbarItem(placement: .topBarLeading) { Button("Resume") { model.showingHome = false } }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("New Project…", systemImage: "folder.badge.plus") { newProject = true }
                        Button("Add Host…", systemImage: "server.rack") { editing = ConnectionProfile() }
                    } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Add")
                }
            }
            .sheet(item: $browsing) { host in
                FolderPickerSheet(start: host.home, host: host) { model.openProject($0, on: host.id) }
            }
            .sheet(item: $finding) { host in FindProjectsSheet(host: host) { model.openProject($0, on: host.id) } }
            .sheet(item: $editing) { profile in ProfileEditor(profile: profile) { model.save($0) } }
            .sheet(isPresented: $newProject) { NewProjectSheet() }
            .sheet(item: $running) { RunsSheet(hostID: $0.hostID, folder: $0.folder) }
            .sheet(item: $pullRequests) { PullRequestsSheet(hostID: $0.hostID, folder: $0.folder) }
            .confirmationDialog("Remove this host?", isPresented: Binding(get: { deletingHost != nil }, set: { if !$0 { deletingHost = nil } }), titleVisibility: .visible) {
                Button("Remove", role: .destructive) { if let deletingHost { model.delete(deletingHost) }; deletingHost = nil }
            } message: { Text("Its saved password or key is removed from this phone. Nothing changes on the host.") }
        }
    }

    private var list: some View {
        List {
            ForEach(model.profiles) { profile in
                let host = model.connection(for: profile.id)
                let online = host?.isConnected == true
                let projects = ProjectCache.paths(host: profile.id.uuidString).filter { $0 != host?.home }
                let counts = Dictionary(uniqueKeysWithValues: TabsModel.savedProjects(profileKey: profile.id.uuidString).map { ($0.path, $0.tabCount) })
                Section {
                    if case .failed(let message) = host?.state {
                        Label(message, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.orange)
                    }
                    if projects.isEmpty {
                        Text(online ? "No projects yet. Add a folder to work in." : "No projects yet. Connect, then add a folder.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(projects, id: \.self) { path in
                        projectRow(path, profile: profile, online: online, tabs: counts[path])
                    }
                    if online, let host {
                        Button { browsing = host } label: { Label("Add Project…", systemImage: "folder.badge.plus") }
                        Button { finding = host } label: { Label("Find Git Projects…", systemImage: "magnifyingglass") }
                    } else if host?.state != .connecting {
                        Button { model.connect(profile) } label: { Label("Connect", systemImage: "bolt.horizontal") }
                    }
                } header: {
                    hostHeader(profile, host: host)
                }
            }
        }
    }

    private func projectRow(_ path: String, profile: ConnectionProfile, online: Bool, tabs: Int?) -> some View {
        Button { model.openProject(path, on: profile.id) } label: {
            HStack {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text((path as NSString).lastPathComponent).foregroundStyle(online ? .primary : .secondary)
                        Text(path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    }
                } icon: { Image(systemName: tabs != nil ? "square.on.square" : "folder") }
                Spacer(minLength: 0)
                if profile.id == model.activeHostID, path == model.activeProjectPath {
                    Text("Open").font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor)
                } else if let tabs {
                    Text("\(tabs) \(tabs == 1 ? "tab" : "tabs")").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .swipeActions {
            Button("Remove", role: .destructive) { model.removeProject(path, on: profile.id) }
            Button("New Chat") { startChat(path, profile: profile) }.tint(.blue)
        }
        .contextMenu {
            Button("Open Workspace", systemImage: "square.on.square") { model.openProject(path, on: profile.id) }
            Button("New Chat Here", systemImage: "square.and.pencil") { startChat(path, profile: profile) }
            if online { Button("Run…", systemImage: "play.circle") { running = ProjectRef(hostID: profile.id, folder: path) } }
            if online { Button("Pull Requests", systemImage: "arrow.triangle.pull") { pullRequests = ProjectRef(hostID: profile.id, folder: path) } }
            Button("Remove from List", systemImage: "minus.circle", role: .destructive) { model.removeProject(path, on: profile.id) }
        }
    }

    private func startChat(_ path: String, profile: ConnectionProfile) {
        let agent = AgentKind(rawValue: UserDefaults.standard.string(forKey: "newchat.agent") ?? "") ?? .claude
        if model.connection(for: profile.id) == nil { model.connect(profile) }
        model.chats.startNew(agent, hostID: profile.id, folder: path)
    }

    private func hostHeader(_ profile: ConnectionProfile, host: HostConnection?) -> some View {
        let online = host?.isConnected == true
        return HStack(spacing: 6) {
            Circle().fill(online ? Color.green : Color.secondary.opacity(0.5)).frame(width: 8, height: 8)
            Text(profile.displayName)
            if host?.state == .connecting { ProgressView().controlSize(.mini) }
            else if !online { Text("Offline").font(.caption2).foregroundStyle(.secondary) }
            Spacer()
            Menu {
                if online { Button("Disconnect", systemImage: "bolt.horizontal.circle") { model.disconnect(profile.id) } }
                else { Button("Connect", systemImage: "bolt.horizontal") { model.connect(profile) } }
                Button("Edit Host…", systemImage: "pencil") { editing = profile }
                Button("Remove Host", systemImage: "trash", role: .destructive) { deletingHost = profile }
            } label: {
                Image(systemName: "ellipsis.circle").font(.body)
            }
            .textCase(nil)
        }
    }
}

/// Adding a project: a host (one of yours, or a new one), then a folder on it.
struct NewProjectSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var hostID: UUID?
    @State private var path = ""
    @State private var addingHost: ConnectionProfile?
    @State private var browsing: HostConnection?
    @State private var finding: HostConnection?

    private var host: HostConnection? { hostID.flatMap { model.connection(for: $0) } }

    var body: some View {
        NavigationStack {
            Form {
                Section("Host") {
                    ForEach(model.profiles) { profile in
                        Button {
                            hostID = profile.id
                            if model.connection(for: profile.id)?.isConnected != true { model.connect(profile) }
                        } label: {
                            HStack {
                                Image(systemName: "server.rack").foregroundStyle(model.connection(for: profile.id)?.isConnected == true ? .green : .secondary)
                                Text(profile.displayName).foregroundStyle(.primary)
                                Spacer()
                                if hostID == profile.id { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                            }
                        }
                    }
                    Button { addingHost = ConnectionProfile() } label: { Label("Add a New Host…", systemImage: "plus") }
                }

                if hostID != nil {
                    Section {
                        if let host, host.isConnected {
                            TextField("Folder path, like ~/code/app", text: $path)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                .font(.system(.body, design: .monospaced))
                            Button { browsing = host } label: { Label("Browse…", systemImage: "folder") }
                            Button { finding = host } label: { Label("Find Git Projects…", systemImage: "magnifyingglass") }
                        } else if case .failed(let message)? = host?.state {
                            Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        } else {
                            HStack { ProgressView(); Text("Connecting…").foregroundStyle(.secondary) }
                        }
                    } header: { Text("Folder") } footer: {
                        Text("The project is the folder agents work in. A path starting with ~ is in the host's home folder.")
                    }
                }
            }
            .navigationTitle("New Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Add") { add(path) }.disabled(resolved(path) == nil) }
            }
            .sheet(item: $addingHost) { profile in
                ProfileEditor(profile: profile) { saved in
                    model.save(saved)
                    hostID = saved.id
                    model.connect(saved)
                }
            }
            .sheet(item: $browsing) { host in FolderPickerSheet(start: host.home, host: host) { add($0) } }
            .sheet(item: $finding) { host in FindProjectsSheet(host: host) { add($0) } }
        }
    }

    /// The typed path made absolute, or nil if there is nothing usable yet.
    private func resolved(_ text: String) -> String? {
        guard let host, host.isConnected else { return nil }
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.count > 1, value.hasSuffix("/") { value.removeLast() }
        guard !value.isEmpty else { return nil }
        if value == "~" { return host.home }
        if value.hasPrefix("~/") { return host.home + value.dropFirst(1) }
        let windowsAbsolute = value.count >= 2 && value.dropFirst().first == ":"
        return value.hasPrefix("/") || windowsAbsolute ? value : host.home + "/" + value
    }

    private func add(_ text: String) {
        guard let host, let folder = resolved(text) else { return }
        ProjectCache.touch(folder, host: host.key)
        dismiss()
    }
}

/// Git projects found on a host. The search runs only because you asked for it.
struct FindProjectsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let host: HostConnection
    let onPick: (String) -> Void
    @State private var found: [String] = []
    @State private var searching = true

    var body: some View {
        NavigationStack {
            List {
                if searching {
                    HStack { ProgressView(); Text("Looking in the home folder…").foregroundStyle(.secondary) }
                } else if found.isEmpty {
                    Text("No git projects found within a few levels of the home folder.").foregroundStyle(.secondary)
                }
                ForEach(found, id: \.self) { path in
                    Button {
                        onPick(path)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text((path as NSString).lastPathComponent).foregroundStyle(.primary)
                            Text(path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                        }
                    }
                }
            }
            .navigationTitle(host.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .task {
                found = await host.findProjects()
                searching = false
            }
        }
    }
}

/// Picks the host and project a new chat starts in.
struct ProjectPickSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let title: String
    let onPick: (UUID, String) -> Void
    @State private var browsing: HostConnection?

    var body: some View {
        NavigationStack {
            List {
                if model.connectedHosts.isEmpty {
                    Text("Connect to a host first.").foregroundStyle(.secondary)
                }
                ForEach(model.connectedHosts) { host in
                    Section(host.name) {
                        ForEach(ProjectCache.paths(host: host.key).filter { $0 != host.home }, id: \.self) { path in
                            Button { onPick(host.id, path); dismiss() } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text((path as NSString).lastPathComponent).foregroundStyle(.primary)
                                    Text(path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                                }
                            }
                        }
                        Button { browsing = host } label: { Label("Browse for a Folder…", systemImage: "folder.badge.plus") }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .sheet(item: $browsing) { host in
                FolderPickerSheet(start: host.home, host: host) { onPick(host.id, $0); dismiss() }
            }
        }
    }
}
