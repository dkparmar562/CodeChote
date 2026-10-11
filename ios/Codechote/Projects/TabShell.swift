import SwiftUI
import UIKit

/// The app once connected: tabs that behave like the iOS app switcher. Drag along the bottom bar to move
/// between tabs (the screens slide as cards under your finger), swipe up on it to see every tab as a card,
/// and swipe a card up to close it. "+" opens the new-tab page.
struct TabShell: View {
    @Environment(AppModel.self) private var model
    let tabs: TabsModel

    @State private var keyboardVisible = false
    /// Tabs are created the first time they are shown, then kept alive so terminals and the
    /// workbench keep their state while you are elsewhere.
    @State private var visited: Set<UUID> = []

    // Gesture state
    private enum Axis { case horizontal, vertical }
    @State private var axis: Axis?
    @State private var dragX: CGFloat = 0     // horizontal travel while switching
    @State private var lift: CGFloat = 0      // 0...1, how far the screen is pulled up towards the switcher
    @State private var gesturing = false

    private let gap: CGFloat = 16

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(Array(tabs.tabs.enumerated()), id: \.element.id) { index, tab in
                    if visited.contains(tab.id) || tab.id == tabs.selectedID {
                        card(for: tab, index: index, width: geo.size.width)
                    }
                }
                if tabs.tabs.isEmpty { EmptyTabsView(tabs: tabs) }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            do {
                TabCapsule(tabs: tabs, compact: keyboardVisible, onOpen: { captureCurrent(); tabs.showOverview = true }, onChanged: panChanged, onEnded: { value, width in panEnded(value, width: width) })
                    .opacity(tabs.showOverview ? 0 : 1)
            }
        }
        .overlay(alignment: .top) { ConnectionBanner() }
        .overlay { if tabs.showOverview { TabSwitcher(tabs: tabs).transition(.opacity) } }
        .sheet(isPresented: Binding(get: { tabs.showNewTab }, set: { tabs.showNewTab = $0 })) {
            NewTabPage(tabs: tabs)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .animation(.smooth(duration: 0.28), value: tabs.showOverview)
        .onChange(of: tabs.selectedID, initial: true) { _, id in if let id { visited.insert(id) } }
        .onAppear {
            // Photograph the outgoing tab for the switcher, unless a gesture already did.
            tabs.willChangeSelection = { if !gesturing { captureCurrent() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardVisible = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardVisible = false }
        .onAppear { if tabs.tabs.isEmpty { tabs.open(.files) } }
        #if targetEnvironment(simulator)
        .onAppear {
            // `-devDrag 0.4`: hold a sideways swipe that far through (simulator screenshots).
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-devDrag"), i + 1 < args.count, let fraction = Double(args[i + 1]) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 9) {
                    if let selected = tabs.selectedIndex { for index in [selected - 1, selected + 1] where tabs.tabs.indices.contains(index) { visited.insert(tabs.tabs[index].id) } }
                    axis = .horizontal; gesturing = true
                    dragX = -CGFloat(fraction) * UIScreen.main.bounds.width
                }
            }
            if args.contains("-devLift") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 9) { axis = .vertical; gesturing = true; lift = 0.6 }
            }
        }
        #endif
    }

    // MARK: Cards

    @ViewBuilder
    private func card(for tab: AppTab, index: Int, width: CGFloat) -> some View {
        let selected = tabs.selectedIndex ?? 0
        let offset = index - selected
        let isCurrent = offset == 0
        let progress = min(1, abs(dragX) / max(width, 1))
        let showsNeighbour = gesturing && axis == .horizontal && abs(offset) == 1
        let rounded = gesturing || lift > 0
        TabContent(tab: tab, tabs: tabs, isSelected: isCurrent)
            .clipShape(RoundedRectangle(cornerRadius: rounded ? 38 : 0, style: .continuous))
            .shadow(color: .black.opacity(rounded ? 0.28 : 0), radius: 16, y: 6)
            .scaleEffect(isCurrent ? 1 - 0.08 * progress - 0.30 * lift : 0.92 + 0.08 * progress)
            .offset(x: CGFloat(offset) * (width + gap) + dragX, y: isCurrent ? -lift * 90 : 0)
            .opacity(isCurrent || showsNeighbour ? 1 : 0)
            .allowsHitTesting(isCurrent && !gesturing)
            .accessibilityHidden(!isCurrent)
    }

    // MARK: Gestures

    private func panChanged(_ value: DragGesture.Value) {
        let t = value.translation
        if axis == nil {
            axis = abs(t.width) >= abs(t.height) ? .horizontal : .vertical
            gesturing = true
            captureCurrent()
            // The neighbours must exist before they can slide in.
            if let selected = tabs.selectedIndex {
                for index in [selected - 1, selected + 1] where tabs.tabs.indices.contains(index) { visited.insert(tabs.tabs[index].id) }
            }
        }
        switch axis {
        case .horizontal:
            let selected = tabs.selectedIndex ?? 0
            let atStart = t.width > 0 && selected == 0
            let atEnd = t.width < 0 && selected == tabs.tabs.count - 1
            // Pull against the end with resistance, like the real switcher.
            dragX = (atStart || atEnd) ? t.width * 0.25 : t.width
        case .vertical:
            lift = max(0, min(1, -t.height / 260))
        case nil: break
        }
    }

    private func panEnded(_ value: DragGesture.Value, width: CGFloat) {
        let t = value.translation, predicted = value.predictedEndTranslation
        defer { axis = nil }

        if axis == .horizontal {
            let selected = tabs.selectedIndex ?? 0
            let direction = (t.width < -width * 0.25 || predicted.width < -width * 0.6) ? 1
                : (t.width > width * 0.25 || predicted.width > width * 0.6) ? -1 : 0
            if direction != 0, tabs.tabs.indices.contains(selected + direction) {
                withAnimation(.smooth(duration: 0.26)) {
                    dragX = CGFloat(-direction) * (width + gap)
                } completion: {
                    var transaction = Transaction(); transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        tabs.step(direction)
                        dragX = 0
                        gesturing = false
                    }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            } else {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { dragX = 0 } completion: { gesturing = false }
            }
        } else if axis == .vertical {
            if lift > 0.28 || predicted.height < -260 {
                captureCurrent()
                withAnimation(.smooth(duration: 0.3)) { tabs.showOverview = true }
                // Leave the screen where it is; reset once the switcher covers it.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    var transaction = Transaction(); transaction.disablesAnimations = true
                    withTransaction(transaction) { lift = 0; gesturing = false }
                }
            } else {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { lift = 0 } completion: { gesturing = false }
            }
        } else {
            gesturing = false
        }
    }

    /// A picture of what is on screen now (without the bottom bar), for the switcher cards.
    private func captureCurrent() {
        guard let id = tabs.selectedID, !tabs.showOverview else { return }
        if let image = TabSnapshots.captureScreen() { tabs.snapshots[id] = image }
    }
}

/// Takes pictures of the live screen for the switcher.
enum TabSnapshots {
    @MainActor
    static func captureScreen() -> UIImage? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first,
              let window = scene.windows.first(where: \.isKeyWindow) ?? scene.windows.first else { return nil }
        let bar: CGFloat = 96 + window.safeAreaInsets.bottom        // leave the tab bar out of the picture
        let size = CGSize(width: window.bounds.width, height: max(100, window.bounds.height - bar))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1.5
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }
}

/// Picks the right screen for a tab.
struct TabContent: View {
    let tab: AppTab
    let tabs: TabsModel
    let isSelected: Bool

    var body: some View {
        switch tab.kind {
        case .workbench, .window: WorkbenchTab(tab: tab, tabs: tabs, isSelected: isSelected)
        case .files: FilesTab(tabs: tabs)
        case .git: GitTab(tabs: tabs)
        case .agents: MovedToChats(tabs: tabs, tab: tab, chat: nil)
        case .browser: BrowserTab(tab: tab, tabs: tabs, isSelected: isSelected)
        case .screen: RemoteScreenTab(tab: tab, tabs: tabs, isSelected: isSelected)
        case .terminal, .agentTerminal: TerminalTab(tab: tab, tabs: tabs, isSelected: isSelected)
        case .chat(let agent, let session): MovedToChats(tabs: tabs, tab: tab, chat: (agent, session))
        case .file(let path): EditorTab(tab: tab, tabs: tabs, path: path)
        }
    }
}

struct EmptyTabsView: View {
    let tabs: TabsModel
    var body: some View {
        ContentUnavailableView {
            Label("No tabs open", systemImage: "square.on.square")
        } description: {
            Text("Open something to get started.")
        } actions: {
            Button("New Tab") { tabs.showNewTab = true }.buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - Bottom capsule

struct TabCapsule: View {
    @Environment(AppModel.self) private var model
    let tabs: TabsModel
    /// Slimmer while the keyboard is up, so it stays reachable above it.
    var compact = false
    let onOpen: () -> Void
    let onChanged: (DragGesture.Value) -> Void
    let onEnded: (DragGesture.Value, CGFloat) -> Void

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: tabs.selected?.kind.symbol ?? "square.on.square")
                        .font(.system(size: 17, weight: .medium))
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(tabs.selected?.title ?? "No tabs")
                            .font(.system(size: 15, weight: .semibold))
                            .lineLimit(1)
                        if !compact, let detail = tabs.selected?.detail, !detail.isEmpty {
                            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                        }
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: 4) {
                        Image(systemName: "square.on.square").font(.system(size: 14))
                        Text("\(tabs.tabs.count)").font(.system(size: 13, weight: .semibold)).monospacedDigit()
                    }
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .frame(height: compact ? 42 : 56)
                .contentShape(Capsule())
                .glass(in: Capsule(), interactive: true)
                .onTapGesture(perform: onOpen)
                .contextMenu {
                    Button("Hosts, Projects & Agents", systemImage: "square.grid.2x2") { model.goHome() }
                    Button("All Tabs", systemImage: "square.on.square", action: onOpen)
                }
                .gesture(
                    DragGesture(minimumDistance: 6)
                        .onChanged(onChanged)
                        .onEnded { onEnded($0, geo.size.width) }
                )
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("\(tabs.selected?.title ?? "No tabs"). Swipe sideways to change tab, up for all tabs")
                .accessibilityAction(named: "Show all tabs", onOpen)
                .accessibilityAction(named: "Next tab") { tabs.step(1) }
                .accessibilityAction(named: "Previous tab") { tabs.step(-1) }

                // With the keyboard up (terminal, editor, VS Code), this button puts it away instead.
                Button {
                    if compact {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    } else {
                        tabs.showNewTab = true
                    }
                } label: {
                    Image(systemName: compact ? "keyboard.chevron.compact.down" : "plus")
                        .font(.system(size: compact ? 17 : 20, weight: .semibold))
                        .frame(width: compact ? 42 : 56, height: compact ? 42 : 56)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glass(in: Circle(), interactive: true)
                .accessibilityLabel(compact ? "Hide keyboard" : "New tab")
            }
            .glassGroup(spacing: 14)
        }
        .frame(height: compact ? 42 : 56)
        .padding(.horizontal, 12)
        .padding(.top, compact ? 2 : 6)
        .padding(.bottom, compact ? 2 : 4)
    }
}

// MARK: - Switcher

/// Safari-style tab overview: every tab as a card in a two-column grid. Tap a card to open it, swipe it
/// sideways or up (or tap its x) to close it. New tab and Done sit in a glass bar at the bottom.
struct TabSwitcher: View {
    @Environment(AppModel.self) private var model
    let tabs: TabsModel
    @State private var appeared = false

    var body: some View {
        GeometryReader { geo in
            let spacing: CGFloat = 16
            let cardWidth = (geo.size.width - spacing * 3) / 2
            let cardHeight = cardWidth * 1.42
            ZStack(alignment: .bottom) {
                Rectangle().fill(.regularMaterial).ignoresSafeArea()
                    .onTapGesture { withAnimation(.smooth(duration: 0.3)) { tabs.showOverview = false } }

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.fixed(cardWidth), spacing: spacing), GridItem(.fixed(cardWidth), spacing: spacing)], spacing: 22) {
                            ForEach(Array(tabs.tabs.enumerated()), id: \.element.id) { index, tab in
                                SwitcherCard(tab: tab, tabs: tabs, width: cardWidth, height: cardHeight)
                                    .id(tab.id)
                                    .scaleEffect(appeared ? 1 : 1.12)
                                    .opacity(appeared ? 1 : 0)
                                    .animation(.smooth(duration: 0.38).delay(Double(min(index, 6)) * 0.015), value: appeared)
                                    .transition(.scale(scale: 0.8).combined(with: .opacity))
                            }
                        }
                        .padding(.horizontal, spacing)
                        .padding(.top, 12)
                        .padding(.bottom, 110)
                        .animation(.smooth(duration: 0.3), value: tabs.tabs.map(\.id))
                    }
                    .onAppear {
                        if let id = tabs.selectedID { proxy.scrollTo(id, anchor: .center) }
                        appeared = true
                    }
                }

                HStack(spacing: 12) {
                    Button { tabs.showOverview = false; model.goHome() } label: {
                        Image(systemName: "square.grid.2x2").font(.system(size: 19, weight: .semibold)).frame(width: 54, height: 54)
                    }
                    .buttonStyle(.plain).glass(in: Circle(), interactive: true)
                    .accessibilityLabel("Hosts, projects and agents")
                    Button { tabs.showOverview = false; tabs.showNewTab = true } label: {
                        Image(systemName: "plus").font(.system(size: 20, weight: .semibold)).frame(width: 54, height: 54)
                    }
                    .buttonStyle(.plain).glass(in: Circle(), interactive: true)
                    .accessibilityLabel("New Tab")
                    Spacer()
                    Text("\(tabs.tabs.count) \(tabs.tabs.count == 1 ? "Tab" : "Tabs")").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                    Spacer()
                    Button { withAnimation(.smooth(duration: 0.3)) { tabs.showOverview = false } } label: {
                        Text("Done").font(.headline).padding(.horizontal, 22).frame(height: 54)
                    }
                    .buttonStyle(.plain).glass(in: Capsule(), tint: .accentColor.opacity(0.3), interactive: true)
                }
                .glassGroup(spacing: 12)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
                .padding(.top, 24)
                .background(alignment: .bottom) {
                    // Cards fade out under the bar, as in Safari.
                    Rectangle().fill(.regularMaterial)
                        .mask(LinearGradient(colors: [.clear, .black, .black], startPoint: .top, endPoint: .bottom))
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }
            }
        }
    }
}

struct SwitcherCard: View {
    let tab: AppTab
    let tabs: TabsModel
    let width: CGFloat
    let height: CGFloat
    @State private var drag: CGSize = .zero

    private var isSelected: Bool { tab.id == tabs.selectedID }

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                ZStack {
                    Rectangle().fill(Color(.secondarySystemBackground))
                    if let image = tabs.snapshots[tab.id] {
                        Image(uiImage: image).resizable().scaledToFill()
                            .frame(width: width, height: height, alignment: .top)
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: tab.kind.symbol).font(.system(size: 34, weight: .light)).foregroundStyle(.secondary)
                            if let detail = tab.detail, !detail.isEmpty {
                                Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(3).multilineTextAlignment(.center).padding(.horizontal, 10)
                            }
                        }
                    }
                }
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: isSelected ? 3 : 1)
                }
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)

                Button { withAnimation(.smooth(duration: 0.28)) { tabs.close(tab.id) } } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).frame(width: 28, height: 28)
                        .glass(in: Circle(), interactive: true)
                }
                .buttonStyle(.plain)
                .padding(8)
                .accessibilityLabel("Close \(tab.title)")
            }

            HStack(spacing: 5) {
                Image(systemName: tab.kind.symbol).font(.system(size: 11, weight: .semibold))
                Text(tab.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
            }
            .frame(width: width, alignment: .leading)
            .padding(.leading, 6)
            .foregroundStyle(.secondary)
        }
        .offset(drag)
        .rotationEffect(.degrees(Double(drag.width) / 40))
        .opacity(1.0 - min(0.7, Double(max(abs(drag.width), -drag.height)) / 320))
        .onTapGesture { withAnimation(.smooth(duration: 0.3)) { tabs.select(tab.id) } }
        // Swipe a card sideways or up to close it, like Safari.
        .gesture(
            DragGesture(minimumDistance: 14)
                .onChanged { value in
                    let t = value.translation
                    if abs(t.width) > abs(t.height) { drag = CGSize(width: t.width, height: 0) }
                    else if t.height < 0 { drag = CGSize(width: 0, height: t.height) }
                }
                .onEnded { value in
                    let t = value.translation, p = value.predictedEndTranslation
                    let closeX = abs(t.width) > 90 || abs(p.width) > 260
                    let closeY = t.height < -90 || p.height < -300
                    if closeX || closeY {
                        let target = closeX ? CGSize(width: (t.width < 0 ? -1 : 1) * 500, height: 0) : CGSize(width: 0, height: -800)
                        withAnimation(.smooth(duration: 0.22)) { drag = target } completion: { withAnimation(.smooth(duration: 0.28)) { tabs.close(tab.id) } }
                    } else {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { drag = .zero }
                    }
                }
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: "Close tab") { tabs.close(tab.id) }
    }
}

// MARK: - New tab page

struct NewTabPage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let tabs: TabsModel

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    section("Workspace") {
                        tile("Files", "folder", .blue) { tabs.open(.files) }
                        tile("Source Control", "arrow.triangle.branch", .orange) { tabs.open(.git) }
                        tile("Terminal", "terminal", .green) { tabs.open(.terminal, detail: model.rootFolder) }
                        tile("VS Code", "chevron.left.forwardslash.chevron.right", .indigo) { tabs.open(.workbench) }
                        tile("Browser", "globe", .cyan) { tabs.open(.browser(url: "")) }
                        tile("Remote screen", "display", .mint) { tabs.open(.screen(port: 5900)) }
                        tile("Hosts & projects", "square.grid.2x2", .teal) { model.goHome() }
                        tile("New VS Code window", "macwindow.badge.plus", .indigo) { tabs.open(.window(folder: model.rootFolder)) }
                    }

                    VSCodeScreens(tabs: tabs, dismiss: dismiss)

                    section("AI agents") {
                        tile("All chats", "bubble.left.and.bubble.right", .pink) { model.goHome(.chats) }
                        ForEach(AgentKind.allCases) { agent in
                            // Chats open on the chats screen, outside the tabs; Antigravity lives in VS Code.
                            providerTile(agent) {
                                if agent.tier == .chat, let hostID = model.activeHostID { model.chats.startNew(agent, hostID: hostID, folder: model.rootFolder) }
                                else { tabs.launch(agent, folder: model.rootFolder) }
                            }
                        }
                    }

                    if !model.recentFolders.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Recent folders").font(.footnote.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                            ForEach(model.recentFolders.prefix(5), id: \.self) { path in
                                Button {
                                    model.setRootFolder(path)
                                    tabs.open(.files)
                                } label: {
                                    HStack {
                                        Image(systemName: "clock.arrow.circlepath").frame(width: 28)
                                        VStack(alignment: .leading) {
                                            Text((path as NSString).lastPathComponent).font(.body)
                                            Text(path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                                        }
                                        Spacer()
                                    }
                                    .padding(12)
                                    .frame(maxWidth: .infinity)
                                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(16)
            }
            .navigationTitle("New tab")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.footnote.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            LazyVGrid(columns: columns, spacing: 12, content: content)
        }
    }

    private func providerTile(_ agent: AgentKind, action: @escaping () -> Void) -> some View {
        Button {
            action()
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                AgentIcon(agent: agent, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(agent.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.primary).multilineTextAlignment(.leading)
                    Text(agent.launchNote).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
    }

    private func tile(_ title: String, _ symbol: String, _ tint: Color, action: @escaping () -> Void) -> some View {
        Button {
            action()
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: symbol).font(.system(size: 22, weight: .medium)).foregroundStyle(tint)
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.primary).multilineTextAlignment(.leading)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Connection banner

struct ConnectionBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            switch model.connection {
            case .connected:
                EmptyView()
            case .reconnecting:
                banner("Reconnecting…", symbol: nil, showsSpinner: true)
            case .failed(let message):
                banner(message, symbol: "exclamationmark.triangle.fill", showsSpinner: false)
            }
        }
        .animation(.smooth, value: model.connection)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func banner(_ text: String, symbol: String?, showsSpinner: Bool) -> some View {
        HStack(spacing: 8) {
            if showsSpinner { ProgressView().controlSize(.small) }
            if let symbol { Image(systemName: symbol).foregroundStyle(.orange) }
            Text(text).font(.system(size: 14, weight: .medium)).lineLimit(2)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .glass(in: Capsule())
        .padding(.top, 8)
    }
}

// MARK: - VS Code's own screens

/// The screens of the VS Code window in front (Explorer, Source Control, panels, open files, ...), in the
/// same list as every other tab. Tapping one shows that window and switches it to that screen.
struct VSCodeScreens: View {
    let tabs: TabsModel
    let dismiss: DismissAction

    var body: some View {
        let target = WorkbenchSnapshots.shared.frontWindow(in: tabs)
        if let target, !target.nav.destinations.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Text("VS Code · \(target.title)").font(.footnote.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                ForEach(Destination.Group.allCases, id: \.self) { group in
                    let items = target.nav.destinations(in: group)
                    if !items.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(group.title).font(.caption).foregroundStyle(.tertiary)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(items) { item in
                                        Button {
                                            tabs.select(target.tabID)
                                            target.nav.activate(item.id)
                                            dismiss()
                                        } label: {
                                            HStack(spacing: 8) {
                                                DestinationIcon(destination: item).frame(width: 20, height: 20)
                                                Text(item.title).font(.subheadline).lineLimit(1)
                                            }
                                            .padding(.horizontal, 12).padding(.vertical, 10)
                                            .background(.thinMaterial, in: Capsule())
                                            .overlay { if target.nav.activeID == item.id { Capsule().stroke(Color.accentColor, lineWidth: 1.5) } }
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
