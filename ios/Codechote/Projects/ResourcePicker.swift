import SwiftUI

struct DirectoryEntry: Identifiable, Hashable {
    let name: String
    let isDirectory: Bool
    var id: String { name }
}

struct DirectoryListing {
    /// Absolute path the listing is for (after `~` and symlinks are resolved by the host).
    let path: String
    let entries: [DirectoryEntry]
}

struct PickRequest: Identifiable {
    enum Mode: String { case folder, file, any }
    let id: String
    let mode: Mode
    let title: String
    let startPath: String?
}

/// A touch-friendly file and folder browser for the remote host. Replaces the desktop-style
/// "Open Folder" dialog: tap folders to go in, tap Open to choose the current one.
struct ResourcePicker: View {
    let nav: NavModel
    let request: PickRequest

    @State private var listing: DirectoryListing?
    @State private var errorText: String?
    @State private var isLoading = false
    @State private var showHidden = false
    @State private var showRecents = true

    private var canChooseFolder: Bool { request.mode != .file }
    private var canChooseFile: Bool { request.mode != .folder }

    var body: some View {
        NavigationStack {
            List {
                if let errorText {
                    Section { Label(errorText, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                }

                if showRecents, canChooseFolder, !nav.recentFolders.isEmpty {
                    Section("Recent") {
                        ForEach(nav.recentFolders, id: \.self) { path in
                            Button { choose(path) } label: {
                                Label {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text((path as NSString).lastPathComponent).foregroundStyle(.primary)
                                        Text(path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                                    }
                                } icon: { Image(systemName: "clock.arrow.circlepath") }
                            }
                        }
                    }
                }

                if let listing {
                    Section {
                        if listing.path != "/" && !listing.path.isEmpty {
                            Button { load(parent(of: listing.path)) } label: {
                                Label("Parent Folder", systemImage: "arrow.up.left")
                            }
                        }
                        ForEach(visibleEntries(listing)) { entry in
                            Button {
                                if entry.isDirectory {
                                    load(join(listing.path, entry.name))
                                } else if canChooseFile {
                                    choose(join(listing.path, entry.name))
                                }
                            } label: {
                                HStack {
                                    Label(entry.name, systemImage: entry.isDirectory ? "folder.fill" : "doc.text")
                                        .foregroundStyle(entry.isDirectory || canChooseFile ? Color.primary : Color.secondary)
                                    Spacer()
                                    if entry.isDirectory { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
                                }
                            }
                            .disabled(!entry.isDirectory && !canChooseFile)
                        }
                    } header: {
                        Text(listing.path.isEmpty ? "Drives" : listing.path).font(.caption.monospaced()).lineLimit(1).truncationMode(.head).textCase(nil)
                    }
                }
            }
            .overlay { if isLoading && listing == nil { ProgressView() } }
            .navigationTitle(request.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { nav.finishPick(nil) } }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Toggle("Show Hidden Files", isOn: $showHidden)
                        Button("Home Folder", systemImage: "house") { load("") }
                        if nav.isWindows {
                            Button("Drives", systemImage: "externaldrive") { load(HostPath.drives) }
                        } else {
                            Button("Root", systemImage: "externaldrive") { load("/") }
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if canChooseFolder, let listing, !listing.path.isEmpty {
                    Button { choose(listing.path) } label: {
                        Text("Open “\(HostPath.lastComponent(listing.path).isEmpty ? "/" : HostPath.lastComponent(listing.path))”")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 28)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }
            }
        }
        .task { load(request.startPath ?? nav.lastPickPath ?? "") }
    }

    private func visibleEntries(_ listing: DirectoryListing) -> [DirectoryEntry] {
        listing.entries.filter { showHidden || !$0.name.hasPrefix(".") }
    }

    private func load(_ path: String) {
        guard let lister = nav.lister else { errorText = "Not connected to a host."; return }
        showRecents = false
        isLoading = true
        errorText = nil
        Task {
            do {
                let result = try await lister(path)
                listing = result
                nav.lastPickPath = result.path
            } catch {
                errorText = (error as? LocalizedError)?.errorDescription ?? "Couldn't open that folder. (\(error))"
            }
            isLoading = false
        }
    }

    private func choose(_ path: String) {
        nav.finishPick(path)
    }

    private func parent(of path: String) -> String { HostPath.parent(path, windows: nav.isWindows) }
    private func join(_ base: String, _ name: String) -> String { HostPath.join(base, name, windows: nav.isWindows) }
}
