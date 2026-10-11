import ActivityKit
import Foundation

/// The Live Activity for agents at work: on the Lock Screen and in the Dynamic Island. Shared by the app, which
/// starts and updates it, and the widget extension, which draws it.
struct AgentActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        /// Chats with an agent working right now.
        var working: Int
        /// Chats waiting for you: an approval, a question or a plan.
        var waiting: Int
        /// The most recent chat's title, and what it is doing.
        var headline: String
        var detail: String
        var updated: Date
    }
}
