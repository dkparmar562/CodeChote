import SwiftUI

// MARK: - Usage

struct UsageSection: View {
    let usage: UsageStore
    /// Asks a host again (the refresh button in its section's header), by host name.
    var onRefresh: ((String) async -> Void)?

    /// Reports grouped by host, in the order they came.
    private var groups: [(host: String, reports: [UsageReport])] {
        var order: [String] = [], byHost: [String: [UsageReport]] = [:]
        for report in usage.reports {
            if byHost[report.host] == nil { order.append(report.host) }
            byHost[report.host, default: []].append(report)
        }
        return order.map { ($0, byHost[$0] ?? []) }
    }

    var body: some View {
        if usage.reports.isEmpty {
            Section {
                HStack { Spacer(); if usage.isLoading { ProgressView() } else { Text("No agents found on the connected hosts.").font(.footnote).foregroundStyle(.secondary) }; Spacer() }
                    .listRowBackground(Color.clear)
            } header: { Text("Usage") }
        } else {
            ForEach(Array(groups.enumerated()), id: \.element.host) { index, group in
                Section {
                    ForEach(group.reports, id: \.key) { report in UsageCard(report: report) }
                } header: {
                    header(group.host)
                } footer: {
                    if index == groups.count - 1 { Text("Limits as each agent reports them, for the account it is signed in with.") }
                }
            }
        }
    }

    /// "Usage · My Mac" with that host's refresh button.
    private func header(_ host: String) -> some View {
        HStack {
            Text(host.isEmpty ? "Usage" : "Usage · \(host)")
            Spacer()
            if let onRefresh {
                if usage.loadingHosts.contains(host) {
                    ProgressView().controlSize(.small)
                } else {
                    Button { Task { await onRefresh(host) } } label: { Image(systemName: "arrow.clockwise") }
                        .font(.subheadline.weight(.semibold))
                        .accessibilityLabel("Refresh usage for \(host)")
                }
            }
        }
    }
}

private struct UsageCard: View {
    let report: UsageReport

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                AgentIcon(agent: report.agent, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(report.agent.title).font(.subheadline.weight(.semibold))
                    if let account = report.account { Text(account).font(.caption).foregroundStyle(.secondary).lineLimit(1).textSelection(.enabled) }
                }
            }
            ForEach(report.meters) { meter in UsageBar(meter: meter) }
            if let note = report.note { Text(note).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(.vertical, 4)
    }
}

private struct UsageBar: View {
    let meter: UsageMeter

    private var tint: Color {
        guard let f = meter.fraction else { return .secondary }
        return f >= 0.9 ? .red : f >= 0.75 ? .orange : .blue
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(meter.label).font(.footnote)
                Spacer()
                if let f = meter.fraction { Text("\(Int((f * 100).rounded()))% used").font(.footnote.monospacedDigit()).foregroundStyle(.secondary) }
                else if let detail = meter.detail { Text(detail).font(.footnote.monospacedDigit()).foregroundStyle(.secondary) }
            }
            if let f = meter.fraction {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.18))
                        Capsule().fill(tint.gradient).frame(width: max(6, geo.size.width * f))
                    }
                }
                .frame(height: 8)
                HStack {
                    Text("\(Int(((1 - f) * 100).rounded()))% left").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    if let reset = meter.resetsAt { Text("Resets in \(Self.countdown(to: reset))").font(.caption2).foregroundStyle(.secondary) }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    static func countdown(to date: Date) -> String {
        let minutes = max(0, Int(date.timeIntervalSinceNow / 60))
        if minutes >= 1440 { return "\(minutes / 1440)d \((minutes % 1440) / 60)h" }
        if minutes >= 60 { return "\(minutes / 60)h \(minutes % 60)m" }
        return "\(minutes)m"
    }
}

// MARK: - Settings

/// Per-agent models, and whether to show usage.
struct AgentSettingsView: View {
    let usage: UsageStore
    @Environment(\.dismiss) private var dismiss
    @State private var refresh = 0

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("Show Usage in Chats", isOn: Bindable(usage).showUsage)
                    if usage.showUsage {
                        Toggle(isOn: Bindable(usage).planLookup) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Claude plan usage")
                                Text("Asks Anthropic's usage service from the host, with Claude Code's sign-in. The token stays on the host.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: { Text("Usage") } footer: { Text("Shown for Claude Code and Codex, the two that report it.") }

                Section {
                    ForEach(AgentKind.chatKinds) { agent in
                        NavigationLink {
                            ModelPicker(agent: agent) { _ in refresh += 1 }
                        } label: {
                            HStack(spacing: 12) {
                                AgentIcon(agent: agent, size: 28)
                                Text(agent.title)
                                Spacer()
                                Text(agent.selectedModelTitle).foregroundStyle(.secondary).id(refresh)
                            }
                        }
                    }
                } header: { Text("Default model") } footer: { Text("Used for new messages. You can also change it from inside a chat.") }
            }
            .navigationTitle("AI settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }
}
