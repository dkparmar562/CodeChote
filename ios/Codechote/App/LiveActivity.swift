import ActivityKit
import Foundation

/// Keeps one Live Activity up while agents are working or waiting on you, and ends it when none are.
/// It is updated by the app, so it is current while the app runs (there is no push service to update it later).
@MainActor
final class AgentLiveActivity {
    static let shared = AgentLiveActivity()
    private var activity: Activity<AgentActivityAttributes>?
    private var last: AgentActivityAttributes.ContentState?

    func update(working: Int, waiting: Int, headline: String, detail: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { print("[activity] Live Activities are turned off"); return }
        guard working + waiting > 0 else { end(); return }
        let state = AgentActivityAttributes.ContentState(working: working, waiting: waiting, headline: headline, detail: detail, updated: Date())
        guard state.working != last?.working || state.waiting != last?.waiting || state.headline != last?.headline || state.detail != last?.detail else { return }
        last = state
        // An activity the app can no longer update goes stale after a while instead of claiming work forever.
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(30 * 60))
        if let activity {
            Task { await activity.update(content) }
        } else {
            do { activity = try Activity.request(attributes: AgentActivityAttributes(), content: content); print("[activity] started: \(working) working, \(waiting) waiting") }
            catch { print("[activity] couldn't start: \(error)") }
        }
    }

    func end() {
        guard let activity else { return }
        self.activity = nil
        last = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }
}
