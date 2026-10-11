import SwiftUI

struct ChatContent: View {
    @Bindable var chat: ChatModel
    let agent: AgentKind
    @Binding var input: String
    var focused: FocusState<Bool>.Binding
    let folder: String
    /// Inside the project tabs the chat draws its own top row with a way back; on the chats screen the
    /// navigation bar does that, so this is nil.
    let showAllChats: (() -> Void)?
    let openTerminal: () -> Void
    /// Files to start with (sent from another app's share sheet).
    var initialAttachments: [Attachment] = []
    @State private var attachments: [Attachment] = []
    @State private var installing = false
    @State private var reviewing = false
    @State private var index = ComposerIndex()
    @State private var scroll = ScrollPosition(edge: .bottom)
    @State private var atBottom = true
    /// How many of the latest messages are drawn; earlier ones come in pages.
    @State private var shown = ChatItem.page
    /// While earlier messages are added above, what's on screen stays put.
    @State private var keepingPlace = false
    @State private var browserLink: BrowserLink?


    private var firstShown: Int { ChatItem.firstShown(of: chat.messages, count: shown) }

    private func showEarlier() {
        keepingPlace = true
        shown += ChatItem.page
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            keepingPlace = false
        }
    }

    /// Each finished response's text (every reply message of the turn), keyed by its last message.
    private func responseTexts(_ messages: ArraySlice<ChatMessage>) -> [String: String] {
        var result: [String: String] = [:], parts: [String] = [], lastID: String?
        func close() { if let lastID, !parts.isEmpty { result[lastID] = parts.joined(separator: "\n\n") } }
        for message in messages {
            if message.role == .user {
                close(); parts = []; lastID = nil
            } else {
                let text = message.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { parts.append(text) }
                lastID = message.id
            }
        }
        if !chat.isRunning { close() }
        return result
    }

    /// Keeps the latest message in view: always when `force`, otherwise only if you were already at the bottom.
    private func followBottom(force: Bool = false) {
        guard force || atBottom else { return }
        atBottom = true
        // After this update is laid out, so the bottom is the new one.
        Task { scroll.scrollTo(edge: .bottom) }
    }

    var body: some View {
        ScrollView {
            // Not lazy: every row has its real height, so opening at the latest message and keeping it there
            // is exact (a lazy stack guesses heights and can land in the wrong place or on blank space).
            VStack(alignment: .leading, spacing: 14) {
                if chat.messages.isEmpty && !chat.isLoading && chat.sessionID == nil { emptyState }
                let start = firstShown
                if start > 0 {
                    Button(action: showEarlier) {
                        Label("Show Earlier Messages", systemImage: "arrow.up.circle")
                            .font(.footnote.weight(.medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .tint(.secondary)
                }
                let visible = chat.messages[start...]
                let responses = responseTexts(visible)
                let items = ChatItem.items(from: visible)
                let lastUserID = chat.messages.last(where: { $0.role == .user })?.id
                ForEach(items) { item in
                    ChatItemView(item: item, live: chat.isRunning && item.id == items.last?.id)
                        // Rows that didn't change aren't redrawn (typing a message redraws the chat view).
                        .equatable()
                        .contextMenu {
                            switch item.kind {
                            case .user(let message):
                                Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.plainText }
                                if message.id == lastUserID, !chat.isRunning {
                                    Button("Send Again", systemImage: "arrow.clockwise") { chat.retryLast() }
                                }
                            case .text(let text):
                                Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = text }
                            case .thinking, .tools:
                                EmptyView()
                            }
                        }
                    if let id = item.endOf, let text = responses[id] {
                        ResponseActions(text: text, stats: id == chat.messages.last?.id ? chat.lastStats?.summary : nil)
                    }
                }
                if let stats = chat.lastStats, !chat.isRunning, chat.messages.last.flatMap({ responses[$0.id] }) == nil {
                    Text(stats.summary).font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 4)
                }
                if !chat.liveText.isEmpty {
                    MarkdownView(text: chat.liveText).padding(.horizontal, 4)
                } else if chat.isRunning {
                    TypingDots().padding(.horizontal, 4)
                }
                if let plan = chat.openPlan {
                    PlanCard(agent: agent, plan: plan, onApprove: { chat.approvePlan(plan) }, onKeepPlanning: { chat.dismiss(plan.id); focused.wrappedValue = true })
                }
                if let set = chat.openQuestions {
                    QuestionCard(agent: agent, set: set, onSend: { chat.answer(set, reply: $0) }, onSkip: { chat.dismiss(set.id) })
                }
                if chat.pendingApprovals.count > 1 {
                    ApprovalsCard(agent: agent, requests: chat.pendingApprovals,
                                  onApprove: { requests, remember in chat.approve(requests, remember: remember) },
                                  onDecline: { request in chat.decline(request) })
                } else if let request = chat.pendingApprovals.first {
                    ApprovalCard(
                        agent: agent, request: request,
                        onAllow: { chat.approve([request], remember: false) },
                        onAlways: { chat.approve([request], remember: true) },
                        onDecline: { chat.decline(request) }
                    )
                }
                if chat.cliMissing { missingCLI }
                if let error = chat.errorText {
                    Label(error, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.orange).padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading).background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding(.horizontal, 14).padding(.top, 8)
        }
        // A new scroll view once the conversation arrives, so it opens at the bottom of the real content
        // instead of starting empty and jumping.
        .id(chat.messages.isEmpty)
        .scrollPosition($scroll)
        .scrollDismissesKeyboard(.interactively)
        // Opens at the latest message, and stays there while rows above are measured or a reply grows,
        // unless you've scrolled up to read.
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(atBottom || keepingPlace ? .bottom : nil, for: .sizeChanges)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentSize.height - geometry.visibleRect.maxY < 120
        } action: { _, isNear in atBottom = isNear }
        .onChange(of: chat.messages.count) { old, _ in
            // The conversation arriving, or your own message, always brings you down; the agent's only when you
            // are following along.
            followBottom(force: old == 0 || chat.messages.last?.role == .user)
        }
        .onChange(of: chat.liveText) { _, _ in followBottom() }
        .onChange(of: chat.isRunning) { _, _ in followBottom() }
        .onChange(of: chat.pendingApprovals.count) { _, _ in followBottom(force: true) }
        .onChange(of: chat.openQuestions?.id) { _, _ in followBottom(force: true) }
        .onChange(of: chat.openPlan?.id) { _, _ in followBottom(force: true) }
        .overlay(alignment: .bottom) {
            if !atBottom && !chat.messages.isEmpty {
                Button { withAnimation { scroll.scrollTo(edge: .bottom) }; atBottom = true } label: {
                    Image(systemName: "arrow.down").font(.callout.weight(.semibold)).frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .glass(in: Circle())
                .padding(.bottom, 8)
                .transition(.scale.combined(with: .opacity))
                .accessibilityLabel("Scroll to Latest")
            }
        }
        .animation(.snappy(duration: 0.2), value: atBottom)
        .overlay { if chat.isLoading { ProgressView() } }
        // Links to the host's own addresses (the dev server an agent started) open through this chat's host.
        .environment(\.openURL, OpenURLAction { url in
            guard let target = BrowserTarget.parse(url.absoluteString), target.viaHost else { return .systemAction }
            browserLink = BrowserLink(address: url.absoluteString)
            return .handled
        })
        .sheet(item: $browserLink) { BrowserSheet(session: chat.hostSession, address: $0.address) }
        #if targetEnvironment(simulator)
        // `-devOpenLink localhost:8790`: open a link from the chat as a tap would (simulator tests).
        .task {
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-devOpenLink"), i + 1 < args.count {
                try? await Task.sleep(for: .seconds(2))
                browserLink = BrowserLink(address: args[i + 1])
            }
        }
        #endif
        .environment(\.chatHost, chat.hostSession)
        .environment(\.chatFolder, folder)
        .onAppear { if attachments.isEmpty, !initialAttachments.isEmpty { attachments = initialAttachments } }
        .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        .safeAreaInset(edge: .top, spacing: 0) { header }
    }

    private var header: some View {
        VStack(spacing: 8) {
        if let showAllChats {
        HStack(spacing: 8) {
            Button(action: showAllChats) {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left").font(.system(size: 14, weight: .semibold))
                    Text("Chats").font(.subheadline.weight(.medium)).lineLimit(1).fixedSize()
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .glass(in: Capsule(), interactive: true)
            .accessibilityLabel("All conversations")
            AgentIcon(agent: agent, size: 22)
            Text(agent.title).font(.subheadline.weight(.semibold)).lineLimit(1).layoutPriority(1)
            Text("·").foregroundStyle(.tertiary)
            Text((folder as NSString).lastPathComponent).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Menu {
                if agent.command != nil { Button("Open in Terminal", systemImage: "terminal", action: openTerminal) }
                if let id = chat.sessionID { Button("Copy Session ID", systemImage: "doc.on.doc") { UIPasteboard.general.string = id } }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 15, weight: .semibold)).frame(width: 34, height: 30)
            }
            .glass(in: Capsule(), interactive: true)
        }
        }
        HStack(spacing: 8) {
            ModelChip(agent: agent, model: $chat.model)
            Menu {
                Section("What the agent may do") {
                    ForEach(PermissionMode.allCases) { mode in
                        Button { chat.mode = mode } label: {
                            if chat.mode == mode { Label("\(mode.title) – \(mode.detail)", systemImage: "checkmark") } else { Text("\(mode.title) – \(mode.detail)") }
                        }
                    }
                }
            } label: {
                Label(chat.mode.title, systemImage: chat.mode.symbol).font(.caption.weight(.medium)).lineLimit(1).fixedSize().padding(.horizontal, 10).padding(.vertical, 6)
            }
            .glass(in: Capsule(), interactive: true)
            Spacer(minLength: 0)
            let touched = chat.touchedFiles
            if !touched.isEmpty {
                Button { reviewing = true } label: {
                    Label("\(touched.count)", systemImage: "doc.badge.gearshape")
                        .font(.caption.weight(.semibold)).lineLimit(1).fixedSize()
                        .padding(.horizontal, 10).padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .glass(in: Capsule(), interactive: true)
                .accessibilityLabel("\(touched.count) files changed. Review changes")
            }
        }
        }
        .sheet(isPresented: $reviewing) {
            ChatChangesSheet(session: chat.hostSession, folder: folder, touched: chat.touchedFiles)
        }
        #if targetEnvironment(simulator)
        .task(id: "\(chat.touchedFiles.count)-\(chat.isRunning)") {
            if ProcessInfo.processInfo.arguments.contains("-devOpenChanges"), !chat.touchedFiles.isEmpty, !chat.isRunning {
                try? await Task.sleep(for: .seconds(1)); reviewing = true
            }
        }
        #endif
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.bar)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            AgentIcon(agent: agent, size: 54)
            Text("Ask \(agent.title) about \((folder as NSString).lastPathComponent)").font(.headline).multilineTextAlignment(.center)
            Text(chat.mode.detail).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            VStack(spacing: 8) {
                ForEach(["Explain how this project is organised", "Find bugs in my recent changes", "Write tests for the main module"], id: \.self) { suggestion in
                    Button { input = suggestion; focused.wrappedValue = true } label: {
                        Text(suggestion).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading).padding(12)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.top, 50).padding(.horizontal, 10)
    }

    private var missingCLI: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("\(agent.title) isn't installed on this host", systemImage: "exclamationmark.triangle.fill").font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
            Text("Tap Install to run its official installer on the host (you see the command first). Then sign in by running `\(agent.command ?? agent.rawValue)` once in a terminal.")
                .font(.footnote).foregroundStyle(.secondary)
            HStack {
                if !agent.installHint.isEmpty {
                    Button { installing = true } label: { Label("Install…", systemImage: "arrow.down.circle") }.buttonStyle(.borderedProminent)
                }
                Button("Check Again") { chat.retryLocatingCLI(); chat.retryLast() }.buttonStyle(.bordered)
            }
        }
        #if targetEnvironment(simulator)
        .onAppear { if ProcessInfo.processInfo.arguments.contains("-devOpenInstall") { installing = true } }
        #endif
        .sheet(isPresented: $installing) {
            AgentInstallSheet(agent: agent, session: chat.hostSession, folder: folder) {
                // Look for it again, and send the message that was waiting for it.
                chat.retryLocatingCLI()
                chat.retryLast()
            }
        }
        .padding(12).background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
    }

    private var composer: some View {
        VStack(spacing: 6) {
            ForEach(chat.queued) { item in
                HStack(spacing: 8) {
                    Image(systemName: "clock").foregroundStyle(.secondary)
                    Text(item.text.isEmpty ? "Attachment" : item.text).font(.footnote).lineLimit(1)
                    Spacer(minLength: 0)
                    Text("Sends next").font(.caption2).foregroundStyle(.secondary)
                    Button { chat.removeQueued(item.id) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).accessibilityLabel("Remove queued message")
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color.secondary.opacity(0.12), in: Capsule())
                .padding(.horizontal, 12)
            }
            if chat.isUploading {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Sending attachments to the host…").font(.caption).foregroundStyle(.secondary) }
            }
            if !attachments.isEmpty { AttachmentStrip(attachments: $attachments) }
            let suggestions = index.suggestions(for: input)
            if !suggestions.isEmpty {
                SuggestionList(suggestions: suggestions) { input = ComposerIndex.apply($0, to: input) }
            }

            HStack(alignment: .bottom, spacing: 8) {
                AttachMenu(attachments: $attachments)
                TextField(chat.isRunning ? "Write the next message…" :"Message \(agent.title)", text: $input, axis: .vertical)
                    .lineLimit(1...6)
                    .focused(focused)
                    .toolbar {
                        ToolbarItemGroup(placement: .keyboard) {
                            Spacer()
                            Button { focused.wrappedValue = false } label: { Image(systemName: "keyboard.chevron.compact.down") }
                                .accessibilityLabel("Hide keyboard")
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 11)
                    .glass(in: RoundedRectangle(cornerRadius: 22))
                if chat.isRunning {
                    Button { chat.stop() } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(Color.red.opacity(0.85), in: Circle())
                    }
                    .accessibilityLabel(chat.queued.isEmpty ? "Stop" : "Stop and send the next message")
                }
                Button { sendNow() } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(canSend ? Color.accentColor : Color.gray.opacity(0.4), in: Circle())
                }
                .disabled(!canSend)
                .accessibilityLabel(chat.isRunning ? "Queue message" : "Send")
            }
            .padding(.horizontal, 12)
        }
        .padding(.top, 6).padding(.bottom, 6)
        .onChange(of: input) { _, text in
            guard text.hasPrefix("/") || ComposerIndex.mentionToken(in: text) != nil else { return }
            Task { await index.prepare(for: text, agent: agent, folder: folder, session: chat.hostSession) }
        }
    }

    private func sendNow() {
        let text = input, files = attachments
        input = ""; attachments = []
        chat.send(text, attachments: files)
    }

    private var canSend: Bool { !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty }
}

/// Under a finished response: copies its text, like Claude's app.
private struct ResponseActions: View {
    let text: String
    /// The turn's steps, tokens and time, for the latest response.
    var stats: String?
    @State private var copied = false

    var body: some View {
        HStack(spacing: 6) {
            copyButton
            if let stats, !stats.isEmpty { Text(stats).font(.caption2).foregroundStyle(.secondary) }
        }
        .padding(.top, -8)
    }

    private var copyButton: some View {
        Button {
            UIPasteboard.general.string = text
            copied = true
            Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.footnote.weight(.medium))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 32, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .sensoryFeedback(.success, trigger: copied) { _, now in now }
        .accessibilityLabel(copied ? "Copied" : "Copy response")
    }
}

/// A link to open in the browser sheet.
struct BrowserLink: Identifiable {
    let address: String
    var id: String { address }
}
