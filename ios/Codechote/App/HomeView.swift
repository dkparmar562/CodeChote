import SwiftUI

/// The three tabs of the home screen.
enum HomeSection: Hashable {
    case projects, chats, settings
}

/// The home screen: projects (grouped by host), chats in the middle (the default), and settings.
/// Opening a project shows its own tabs; the home screen comes back from the tab switcher.
struct HomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.homeTab) {
            Tab("Projects", systemImage: "folder", value: HomeSection.projects) { ProjectsScreen() }
            Tab("Chats", systemImage: "bubble.left.and.bubble.right", value: HomeSection.chats) { ChatsHome() }
                .badge(model.chats.runningCount)
            Tab("Settings", systemImage: "gearshape", value: HomeSection.settings) { SettingsScreen() }
        }
    }
}
