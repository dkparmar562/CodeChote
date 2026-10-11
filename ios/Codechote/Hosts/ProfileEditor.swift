import SwiftUI

struct ProfileEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var profile: ConnectionProfile
    @State private var secret = ""
    @State private var passphrase = ""
    @State private var showImporter = false
    let onSave: (ConnectionProfile) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name (optional)", text: $profile.name)
                    TextField("Host", text: $profile.host)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    TextField("Port", value: $profile.port, format: .number.grouping(.never))
                        .keyboardType(.numberPad)
                    TextField("Username", text: $profile.username)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section("Authentication") {
                    Picker("Method", selection: $profile.auth) {
                        ForEach(ConnectionProfile.Auth.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if profile.auth == .password {
                        SecureField("Password", text: $secret)
                    } else {
                        TextEditor(text: $secret)
                            .font(.system(.caption, design: .monospaced))
                            .frame(minHeight: 120)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("Import Key File…") { showImporter = true }
                        SecureField("Key passphrase (if any)", text: $passphrase)
                    }
                }
            }
            .navigationTitle(profile.host.isEmpty ? "New server" : profile.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        profile.secret = secret
                        Keychain.set(passphrase, for: profile.secretAccount + ".pass")
                        onSave(profile)
                        dismiss()
                    }
                    .disabled(profile.host.isEmpty || profile.username.isEmpty)
                }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.data, .text]) { result in
                if case .success(let url) = result {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    if let text = try? String(contentsOf: url, encoding: .utf8) { secret = text }
                }
            }
            .onAppear {
                secret = profile.secret
                passphrase = Keychain.get(profile.secretAccount + ".pass") ?? ""
            }
        }
    }
}
