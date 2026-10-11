import SwiftUI

/// One question an agent asked (Claude Code's AskUserQuestion tool), with the answers it offered.
struct QuestionPrompt: Identifiable, Equatable {
    struct Option: Equatable { let label: String; let detail: String }

    let id: Int
    let header: String
    let question: String
    let options: [Option]
    let multiSelect: Bool

    /// Reads the tool's input: `{"questions": [{question, header, options: [{label, description}], multiSelect}]}`.
    static func parse(inputJSON: String) -> [QuestionPrompt] {
        guard let object = AgentJSON.object(inputJSON), let list = object["questions"] as? [[String: Any]] else { return [] }
        return list.enumerated().compactMap { index, entry in
            guard let question = entry["question"] as? String else { return nil }
            let options = (entry["options"] as? [[String: Any]] ?? []).compactMap { option -> Option? in
                guard let label = option["label"] as? String else { return nil }
                return Option(label: label, detail: option["description"] as? String ?? "")
            }
            return QuestionPrompt(id: index, header: entry["header"] as? String ?? "", question: question, options: options, multiSelect: entry["multiSelect"] as? Bool ?? false)
        }
    }
}

/// The questions of one AskUserQuestion call, answered together.
struct QuestionSet: Identifiable, Equatable {
    let id: String
    let questions: [QuestionPrompt]
}

/// A plan the agent wants approved before it changes anything (Claude Code's ExitPlanMode tool).
struct PlanPrompt: Identifiable, Equatable {
    let id: String
    let plan: String

    static func parse(id: String, inputJSON: String) -> PlanPrompt? {
        guard let plan = AgentJSON.object(inputJSON)?["plan"] as? String, !plan.isEmpty else { return nil }
        return PlanPrompt(id: id, plan: plan)
    }
}

struct TodoItem: Identifiable, Equatable {
    enum Status { case pending, active, done }
    let id: Int
    let text: String
    let status: Status

    /// Reads a TodoWrite call: `{"todos": [{content, status, activeForm}]}`.
    static func parse(inputJSON: String) -> [TodoItem] {
        guard let list = AgentJSON.object(inputJSON)?["todos"] as? [[String: Any]] else { return [] }
        return list.enumerated().compactMap { index, entry in
            guard let content = entry["content"] as? String else { return nil }
            let status: Status
            switch entry["status"] as? String {
            case "completed": status = .done
            case "in_progress": status = .active
            default: status = .pending
            }
            return TodoItem(id: index, text: status == .active ? (entry["activeForm"] as? String ?? content) : content, status: status)
        }
    }
}

// MARK: - Views

/// Questions with tappable answers. Sending reports them back to the agent as your reply.
struct QuestionCard: View {
    let agent: AgentKind
    let set: QuestionSet
    let onSend: (String) -> Void
    let onSkip: () -> Void
    @State private var picked: [Int: Set<String>] = [:]

    private var answered: Bool { self.set.questions.allSatisfy { !(picked[$0.id] ?? []).isEmpty } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("\(agent.title) has a question", systemImage: "questionmark.bubble.fill")
                .font(.subheadline.weight(.semibold)).foregroundStyle(.blue)
            ForEach(set.questions) { question in
                VStack(alignment: .leading, spacing: 8) {
                    if !question.header.isEmpty { Text(question.header).font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
                    Text(question.question).font(.subheadline)
                    ForEach(question.options, id: \.label) { option in
                        let selected = picked[question.id]?.contains(option.label) == true
                        Button { toggle(option.label, in: question) } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: selected ? (question.multiSelect ? "checkmark.square.fill" : "largecircle.fill.circle") : (question.multiSelect ? "square" : "circle"))
                                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.label).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                                    if !option.detail.isEmpty { Text(option.detail).font(.caption).foregroundStyle(.secondary) }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(10)
                            .background(selected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Text("Or type your own answer below.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Skip", action: onSkip).buttonStyle(.bordered)
                Button { onSend(reply()) } label: { Text("Send Answer").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).disabled(!answered)
            }
        }
        .padding(14)
        .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(Color.blue.opacity(0.3), lineWidth: 1) }
    }

    private func toggle(_ label: String, in question: QuestionPrompt) {
        var current = picked[question.id] ?? []
        if question.multiSelect {
            if current.contains(label) { current.remove(label) } else { current.insert(label) }
        } else {
            current = [label]
        }
        picked[question.id] = current
        // One question with one answer: tapping it is the answer.
        if set.questions.count == 1 && !question.multiSelect { onSend(reply()) }
    }

    private func reply() -> String {
        set.questions.map { question in
            let labels = question.options.map(\.label).filter { picked[question.id]?.contains($0) == true }
            return "\(question.header.isEmpty ? question.question : question.header): \(labels.joined(separator: ", "))"
        }
        .joined(separator: "\n")
    }
}

/// A plan to approve. Approving switches the chat to editing and tells the agent to go ahead.
struct PlanCard: View {
    let agent: AgentKind
    let plan: PlanPrompt
    let onApprove: () -> Void
    let onKeepPlanning: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("\(agent.title) has a plan", systemImage: "list.bullet.clipboard.fill")
                .font(.subheadline.weight(.semibold)).foregroundStyle(.purple)
            ScrollView { MarkdownView(text: plan.plan).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(maxHeight: 320)
            HStack {
                Button("Keep Planning", action: onKeepPlanning).buttonStyle(.bordered)
                Button { onApprove() } label: { Text("Approve and Start").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent)
            }
            Text("Approving lets it edit files.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .background(Color.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(Color.purple.opacity(0.3), lineWidth: 1) }
    }
}

/// The agent's to-do list, as a checklist.
struct TodoCard: View {
    let items: [TodoItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("To-do", systemImage: "checklist").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(items) { item in
                HStack(alignment: .top, spacing: 8) {
                    switch item.status {
                    case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    case .active: Image(systemName: "circle.dotted.circle").foregroundStyle(Color.accentColor)
                    case .pending: Image(systemName: "circle").foregroundStyle(.secondary)
                    }
                    Text(item.text)
                        .font(.footnote)
                        .strikethrough(item.status == .done)
                        .foregroundStyle(item.status == .done ? .secondary : .primary)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Quick answers for an agent running in a terminal: its approval prompts take a number, y/n, Enter or Esc.
struct AgentAnswerBar: View {
    let send: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                key("1") { send("1") }
                key("2") { send("2") }
                key("3") { send("3") }
                key("y") { send("y") }
                key("n") { send("n") }
                key("Enter") { send("\r") }
                key("Esc") { send("\u{1B}") }
                key("^C") { send("\u{03}") }
            }
            .padding(.horizontal, 8)
        }
        .frame(height: 40)
        .glass(in: Capsule())
        .padding(.horizontal, 8).padding(.bottom, 2)
    }

    private func key(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).font(.system(size: 14, weight: .medium)).frame(minWidth: 30) }
            .buttonStyle(.bordered).tint(.gray)
    }
}
