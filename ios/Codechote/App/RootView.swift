import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            if let tabs = model.tabs { TabShell(tabs: tabs).id(model.activeProjectPath) }
            if model.showingHome || model.tabs == nil { HomeView().transition(.move(edge: .bottom)) }
        }
        .animation(.smooth(duration: 0.35), value: model.showingHome)
        // A finished run, opened from its notification.
        .sheet(item: Binding(get: { model.runs.presented }, set: { model.runs.presented = $0 })) { job in RunOutputView(job: job) }
        // Photos, files or text sent from another app: choose the agent and project for them.
        .sheet(item: Binding(get: { model.sharedItem }, set: { model.sharedItem = $0 }), onDismiss: { model.checkInbox() }) { item in
            NewChatSheet(shared: item)
        }
        .onChange(of: scenePhase) { _, new in
            Notifier.shared.appIsActive = new == .active
            if new == .active { model.didBecomeActive() }
            if new == .background { Notifier.shared.appDidEnterBackground() }
        }
        .alert("Connection failed", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}
