import ActivityKit
import SwiftUI
import WidgetKit

@main
struct CodechoteWidgets: WidgetBundle {
    var body: some Widget { AgentsActivityWidget() }
}

/// Agents working or waiting on you, on the Lock Screen and in the Dynamic Island. Tapping it opens the chats.
struct AgentsActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AgentActivityAttributes.self) { context in
            LockScreenAgents(state: context.state)
                .padding(16)
                .activityBackgroundTint(Color.black.opacity(0.75))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(URL(string: "codechote://chats"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("\(context.state.working)", systemImage: "sparkles").font(.headline).foregroundStyle(.blue)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.waiting > 0 {
                        Label("\(context.state.waiting)", systemImage: "hand.raised.fill").font(.headline).foregroundStyle(.orange)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.headline).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(context.state.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                Image(systemName: context.state.waiting > 0 ? "hand.raised.fill" : "sparkles")
                    .foregroundStyle(context.state.waiting > 0 ? .orange : .blue)
            } compactTrailing: {
                Text("\(context.state.waiting > 0 ? context.state.waiting : context.state.working)")
                    .font(.caption.weight(.semibold)).monospacedDigit()
            } minimal: {
                Image(systemName: context.state.waiting > 0 ? "hand.raised.fill" : "sparkles")
                    .foregroundStyle(context.state.waiting > 0 ? .orange : .blue)
            }
            .widgetURL(URL(string: "codechote://chats"))
        }
    }
}

private struct LockScreenAgents: View {
    let state: AgentActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill((state.waiting > 0 ? Color.orange : Color.blue).opacity(0.25)).frame(width: 44, height: 44)
                Image(systemName: state.waiting > 0 ? "hand.raised.fill" : "sparkles")
                    .font(.title3).foregroundStyle(state.waiting > 0 ? .orange : .blue)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(summary).font(.headline).foregroundStyle(.white)
                Text(state.headline).font(.subheadline).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                Text(state.detail).font(.caption).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private var summary: String {
        var parts: [String] = []
        if state.working > 0 { parts.append(state.working == 1 ? "1 agent working" : "\(state.working) agents working") }
        if state.waiting > 0 { parts.append(state.waiting == 1 ? "1 needs you" : "\(state.waiting) need you") }
        return parts.isEmpty ? "Agents" : parts.joined(separator: " · ")
    }
}
