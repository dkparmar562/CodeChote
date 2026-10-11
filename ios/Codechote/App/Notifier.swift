import Foundation
import UIKit
import UserNotifications

/// Local notifications for agents that need you. These are scheduled by the app itself, so they work while it
/// is open or has just been backgrounded; iOS suspends the app soon after, and without Apple's push service
/// (not available to this internal build) nothing can wake it later.
@MainActor
final class Notifier {
    static let shared = Notifier()
    private let delegate = NotificationDelegate()

    /// Set by the app: whether a tab is on screen right now, and how to open one from a tapped notification.
    var isVisible: (UUID) -> Bool = { _ in false }
    var openTab: (UUID) -> Void = { _ in }
    /// The same for conversations on the chats screen, by chat id.
    var isChatVisible: (String) -> Bool = { _ in false }
    var openChat: (String) -> Void = { _ in }
    var appIsActive = true

    /// Tells you a conversation needs you, unless it is on screen. Tapping it opens that conversation.
    func needsAttention(chat: String, title: String, body: String) {
        if appIsActive && isChatVisible(chat) { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = String(body.prefix(180))
        content.sound = .default
        content.userInfo = ["chat": chat]
        content.threadIdentifier = chat
        // One notification per conversation: a newer one replaces the older.
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "chat-" + chat, content: content, trigger: nil))
    }

    private var runningTurns = 0
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var asked = false

    func install() { UNUserNotificationCenter.current().delegate = delegate }

    /// Asks once, at the first moment it makes sense (the first time an agent is started).
    func requestIfNeeded() {
        guard !asked else { return }
        asked = true
        #if targetEnvironment(simulator)
        // The permission prompt covers simulator screenshots, and its answer can't be scripted.
        if ProcessInfo.processInfo.arguments.contains("-devSSH") { return }
        #endif
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    /// Tells you a tab needs attention, unless you are already looking at it.
    func needsAttention(tab: UUID, title: String, body: String) {
        if appIsActive && isVisible(tab) { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = String(body.prefix(180))
        content.sound = .default
        content.userInfo = ["tab": tab.uuidString]
        content.threadIdentifier = tab.uuidString
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // MARK: Keeping a running turn alive for a moment after the app is backgrounded

    func turnStarted() { runningTurns += 1 }

    func turnEnded() {
        runningTurns = max(0, runningTurns - 1)
        if runningTurns == 0 { endBackgroundTask() }
    }

    func appDidEnterBackground() {
        guard runningTurns > 0, backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "agent-turn") { [weak self] in
            // Out of time: say so, since the reply can't be followed any more.
            Task { @MainActor in
                self?.postStillWorking()
                self?.endBackgroundTask()
            }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private func postStillWorking() {
        let content = UNMutableNotificationContent()
        content.title = "An agent is still working"
        content.body = "Open Codechote to see the result."
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "still-working", content: content, trigger: nil))
    }

    /// A notification was tapped: show the tab it was about.
    fileprivate func opened(tab text: String?, chat: String?) {
        if let chat { openChat(chat); return }
        guard let text, let id = UUID(uuidString: text) else { return }
        openTab(id)
    }
}

/// The system calls these on a background queue, so this class belongs to no actor. It uses the completion-handler
/// forms and hops to the main thread with plain values only.
private final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let tab = response.notification.request.content.userInfo["tab"] as? String
        let chat = response.notification.request.content.userInfo["chat"] as? String
        DispatchQueue.main.async {
            MainActor.assumeIsolated { Notifier.shared.opened(tab: tab, chat: chat) }
            completionHandler()
        }
    }
}

/// Why a turn ended, for the notification text.
enum TurnOutcome: Equatable {
    case finished(preview: String)
    case needsPermission
    case hasQuestion(preview: String)
    case failed(String)

    var title: String {
        switch self {
        case .finished: "Finished"
        case .needsPermission: "Needs your approval"
        case .hasQuestion: "Has a question"
        case .failed: "Stopped with an error"
        }
    }

    var body: String {
        switch self {
        case .finished(let text), .hasQuestion(let text): text
        case .needsPermission: "A tool was blocked. Change the access level or reply."
        case .failed(let message): message
        }
    }

    /// Reads a finished conversation to decide what the agent is waiting for.
    static func from(messages: [ChatMessage], error: String?) -> TurnOutcome {
        if let error, !error.isEmpty { return .failed(error) }
        var lastText = ""
        var turn: [ChatMessage] = []
        for message in messages.reversed() { if message.role == .user { break }; turn.append(message) }   // newest first
        for message in turn {
            for block in message.blocks {
                if case .tool(let call) = block {
                    let result = (call.result ?? "").lowercased()
                    if call.isError, result.contains("permission") || result.contains("requires approval") || result.contains("not allowed") || result.contains("haven't granted") { return .needsPermission }
                    if call.name.lowercased().contains("askuser") { return .hasQuestion(preview: "Waiting for your answer.") }
                    if call.name == "ExitPlanMode" { return .hasQuestion(preview: "A plan is ready for your approval.") }
                }
            }
        }
        for message in turn where message.role == .assistant && lastText.isEmpty {
            for block in message.blocks.reversed() where lastText.isEmpty {
                if case .text(let text) = block { lastText = text.trimmingCharacters(in: .whitespacesAndNewlines) }
            }
        }
        let preview = lastText.isEmpty ? "Your turn." : lastText
        return preview.hasSuffix("?") ? .hasQuestion(preview: preview) : .finished(preview: preview)
    }
}
