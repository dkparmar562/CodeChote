import UIKit

/// Keeps the iPhone from locking while something is working, since iOS pauses the app soon after it locks.
@MainActor
enum ScreenAwake {
    enum Reason: Hashable { case chats, runs }

    private static var reasons: Set<Reason> = []
    private static let key = "screen.keepAwake"

    /// The setting; on unless turned off.
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: key); apply() }
    }

    static func set(_ reason: Reason, _ active: Bool) {
        if active { reasons.insert(reason) } else { reasons.remove(reason) }
        apply()
    }

    private static func apply() {
        let keep = enabled && !reasons.isEmpty
        if UIApplication.shared.isIdleTimerDisabled != keep { UIApplication.shared.isIdleTimerDisabled = keep }
    }
}
