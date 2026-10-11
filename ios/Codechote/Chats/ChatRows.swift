import SwiftUI

// What the chat list is made of: user messages, reply text, folded runs of tool calls, and their cards.

/// What the chat list draws: user messages, and the agent's messages split into their text and runs of tool
/// calls, so a long stretch of tool use reads as one row instead of a wall of cards.
struct ChatItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case user(ChatMessage)
        case text(String)
        case thinking(String)
        case tools([ToolCall])
    }

    /// Stays the same while a run of tool calls grows, so an open group stays open.
    let id: String
    var kind: Kind
    /// On the last item drawn from a message: that message's id (where a finished reply's actions go).
    var endOf: String?

    var isUser: Bool { if case .user = kind { true } else { false } }

    /// Calls shown as their own card (a checklist, or a question or plan note), never folded into a group.
    nonisolated static func standsAlone(_ call: ToolCall) -> Bool { ["TodoWrite", "AskUserQuestion", "ExitPlanMode"].contains(call.name) }

    /// How many of the latest messages a chat draws at first, and how many more each "Show Earlier" adds.
    static let page = 60

    /// Where drawing starts: the latest `count` messages, widened back to where that turn began.
    nonisolated static func firstShown(of messages: [ChatMessage], count: Int) -> Int {
        var start = max(0, messages.count - count)
        var steps = 0
        while start > 0, messages[start].role != .user, steps < 40 { start -= 1; steps += 1 }
        return start
    }

    nonisolated static func items(from messages: ArraySlice<ChatMessage>) -> [ChatItem] {
        var items: [ChatItem] = []
        for message in messages {
            if message.role == .user {
                items.append(ChatItem(id: message.id, kind: .user(message), endOf: message.id))
                continue
            }
            for (index, block) in message.blocks.enumerated() {
                let id = "\(message.id)#\(index)"
                switch block {
                case .text(let text):
                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { items.append(ChatItem(id: id, kind: .text(text))) }
                case .thinking(let text):
                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { items.append(ChatItem(id: id, kind: .thinking(text))) }
                case .tool(let call):
                    if !standsAlone(call), case .tools(let calls)? = items.last?.kind, let first = calls.first, !standsAlone(first) {
                        items[items.count - 1].kind = .tools(calls + [call])
                    } else {
                        items.append(ChatItem(id: id, kind: .tools([call])))
                    }
                }
            }
            // A message with nothing to draw leaves the previous item alone.
            if let last = items.indices.last, !items[last].isUser { items[last].endOf = message.id }
        }
        return items
    }
}

/// One row of the chat list.
struct ChatItemView: View, Equatable {
    let item: ChatItem
    /// The agent is still working on it (a run of tool calls shows its latest step).
    var live = false

    var body: some View {
        switch item.kind {
        case .user(let message): MessageView(message: message)
        case .text(let text): MarkdownView(text: text)
        case .thinking(let text):
            DisclosureGroup { Text(text).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled) } label: {
                Label("Thinking", systemImage: "brain").font(.footnote).foregroundStyle(.secondary)
            }
        case .tools(let calls): ToolGroup(calls: calls, live: live)
        }
    }
}

/// A run of tool calls: a single call is its card; several fold into one "N steps" row that opens to the cards.
/// While the agent is on it, the latest call shows under the row.
struct ToolGroup: View {
    let calls: [ToolCall]
    let live: Bool
    @State private var expanded = false

    var body: some View {
        if calls.count == 1, let call = calls.first {
            ToolCard(call: call)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Button { withAnimation(.snappy(duration: 0.25)) { expanded.toggle() } } label: { header }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(calls.count) steps, \(summary)")
                    .accessibilityHint(expanded ? "Hides the steps" : "Shows each step")
                if expanded {
                    ForEach(calls) { ToolCard(call: $0) }
                } else if live, let last = calls.last {
                    ToolCard(call: last).transition(.opacity)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.stack.3d.up").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary).frame(width: 18)
            Text("\(calls.count) steps").font(.footnote.weight(.semibold))
            Text(summary).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 0)
            let failed = calls.filter(\.isError).count
            if failed > 0 { Text("\(failed) failed").font(.caption2.weight(.semibold)).foregroundStyle(.red) }
            if live && calls.last?.result == nil { ProgressView().controlSize(.mini) }
            Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(.tertiary)
                .rotationEffect(.degrees(expanded ? 90 : 0))
        }
        .padding(10)
        .background(Color(.secondarySystemBackground).opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Color.secondary.opacity(0.18)) }
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }

    /// The tools used, most used first: "Read ×3 · Bash ×2 · Edit".
    private var summary: String {
        var counts: [String: Int] = [:], order: [String] = []
        for call in calls {
            if counts[call.name] == nil { order.append(call.name) }
            counts[call.name, default: 0] += 1
        }
        return order.sorted { counts[$0]! > counts[$1]! }
            .map { counts[$0]! > 1 ? "\($0) ×\(counts[$0]!)" : $0 }
            .joined(separator: " · ")
    }
}

struct MessageView: View {
    let message: ChatMessage

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(message.blocks) { block in
                        if case .text(let text) = block { Text(text).textSelection(.enabled) }
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Color.accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 18))
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 10) {
                ForEach(message.blocks) { block in
                    switch block {
                    case .text(let text): MarkdownView(text: text)
                    case .thinking(let text):
                        DisclosureGroup { Text(text).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled) } label: {
                            Label("Thinking", systemImage: "brain").font(.footnote).foregroundStyle(.secondary)
                        }
                    case .tool(let call): ToolCard(call: call)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct ToolCard: View {
    let call: ToolCall
    @State private var expanded = false
    #if targetEnvironment(simulator)
    nonisolated(unsafe) static var opened = false
    #endif

    private var symbol: String {
        switch call.name {
        case "Bash": "terminal"
        case "Read": "doc.text"
        case "Write", "Edit", "MultiEdit", "NotebookEdit": "pencil.line"
        case "Grep", "Glob": "magnifyingglass"
        case "WebFetch", "WebSearch": "globe"
        case "Task": "person.2"
        case "TodoWrite": "checklist"
        default: "wrench.and.screwdriver"
        }
    }

    var body: some View {
        let todos = call.name == "TodoWrite" ? TodoItem.parse(inputJSON: call.inputJSON) : []
        if !todos.isEmpty { TodoCard(items: todos) }
        else if call.name == "AskUserQuestion" || call.name == "ExitPlanMode" {
            // Shown as a question or plan card instead; here just a note of it in the history.
            Label(call.name == "ExitPlanMode" ? "Proposed a plan" : "Asked you a question", systemImage: call.name == "ExitPlanMode" ? "list.bullet.clipboard" : "questionmark.bubble")
                .font(.footnote).foregroundStyle(.secondary)
        } else { generic }
    }

    /// One line per call; tapping opens it full screen, where files, edits and output are readable.
    private var generic: some View {
        Button { expanded = true } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(call.isError ? .red : .secondary).frame(width: 18)
                Text(call.name).font(.footnote.weight(.semibold))
                Text(call.summary).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                if let counts = editCounts {
                    Text("+\(counts.added)").font(.caption2.monospacedDigit().weight(.semibold)).foregroundStyle(.green)
                    Text("−\(counts.removed)").font(.caption2.monospacedDigit().weight(.semibold)).foregroundStyle(.red)
                }
                if call.result == nil { ProgressView().controlSize(.mini) }
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(.tertiary)
            }
            .padding(10)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(call.isError ? Color.red.opacity(0.4) : .clear) }
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $expanded) { ToolDetailView(call: call).presentationDragIndicator(.visible) }
        #if targetEnvironment(simulator)
        // `-devOpenTool Read`: open the first finished call of that tool (simulator screenshots).
        .task(id: call.result != nil) {
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-devOpenTool"), i + 1 < args.count, args[i + 1] == call.name, call.result != nil, !ToolCard.opened {
                ToolCard.opened = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { expanded = true }
            }
        }
        #endif
    }

    /// Lines added and removed by an edit, for the summary row.
    private var editCounts: (added: Int, removed: Int)? {
        let input = ToolText.input(call)
        var pairs: [(String, String)] = []
        switch call.name {
        case "Edit": pairs = [(input["old_string"] as? String ?? "", input["new_string"] as? String ?? "")]
        case "MultiEdit": pairs = (input["edits"] as? [[String: Any]] ?? []).map { ($0["old_string"] as? String ?? "", $0["new_string"] as? String ?? "") }
        case "Write": return ((input["content"] as? String ?? "").components(separatedBy: "\n").count, 0)
        default: return nil
        }
        var added = 0, removed = 0
        for (old, new) in pairs {
            for line in ToolText.diff(old, new) {
                if case .added = line { added += 1 } else if case .removed = line { removed += 1 }
            }
        }
        return (added, removed)
    }

    private func section(_ title: String, _ text: String, isError: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(isError ? .red : .primary).textSelection(.enabled).fixedSize(horizontal: true, vertical: true)
            }
            .frame(maxHeight: 220)
        }
    }
}

struct TypingDots: View {
    @State private var phase = 0.0
    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3) { i in
                Circle().fill(Color.secondary).frame(width: 7, height: 7)
                    .opacity(0.3 + 0.7 * (sin(phase * 3 - Double(i) * 0.8) + 1) / 2)
            }
        }
        .padding(.vertical, 6)
        .onAppear { withAnimation(.linear(duration: 2).repeatForever(autoreverses: false)) { phase = .pi * 2 } }
    }
}
