import Foundation
import NIOCore
import NIOSSH

struct HostKeyMismatch: LocalizedError {
    let host: String
    var errorDescription: String? {
        "The host key for \(host) changed since you first connected. Refusing to connect. Remove the saved key if you expect this."
    }
}

/// Trust-on-first-use host key validation. The first key seen for host:port is pinned;
/// any later difference fails the connection.
final class TOFUHostKeyDelegate: NIOSSHClientServerAuthenticationDelegate {
    private let id: String
    init(host: String, port: Int) { id = "\(host):\(port)" }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let presented = String(openSSHPublicKey: hostKey)
        let defaults = UserDefaults.standard
        let storeKey = "hostkey.\(id)"
        if let pinned = defaults.string(forKey: storeKey) {
            if pinned == presented {
                validationCompletePromise.succeed(())
            } else {
                validationCompletePromise.fail(HostKeyMismatch(host: id))
            }
        } else {
            defaults.set(presented, forKey: storeKey)
            validationCompletePromise.succeed(())
        }
    }

    static func forget(host: String, port: Int) {
        UserDefaults.standard.removeObject(forKey: "hostkey.\(host):\(port)")
    }
}
