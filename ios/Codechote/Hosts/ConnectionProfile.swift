import Foundation

struct ConnectionProfile: Codable, Identifiable, Hashable {
    enum Auth: String, Codable, CaseIterable, Identifiable {
        case password = "Password"
        case privateKey = "Private key"
        var id: String { rawValue }
    }

    var id = UUID()
    var name = ""
    var host = ""
    var port = 22
    var username = ""
    var auth: Auth = .password

    var displayName: String { name.isEmpty ? "\(username)@\(host)" : name }
    /// Keychain account holding the password or private key text.
    var secretAccount: String { "profile-\(id.uuidString)" }
    var secret: String {
        get { Keychain.get(secretAccount) ?? "" }
        nonmutating set { Keychain.set(newValue, for: secretAccount) }
    }
}

/// Persists the list of profiles (secrets live in the Keychain, not here).
enum ProfileStore {
    private static let key = "profiles.v1"

    static func load() -> [ConnectionProfile] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([ConnectionProfile].self, from: data) else { return [] }
        return list
    }

    static func save(_ list: [ConnectionProfile]) {
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
