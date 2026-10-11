import SwiftUI

@main
struct CodechoteApp: App {
    @State private var model = AppModel()

    init() {
        setvbuf(stdout, nil, _IOLBF, 0) // flush each line so `devicectl --console` shows logs live
        Notifier.shared.install()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                // codechote://chats (the Live Activity) opens the chats screen.
                .onOpenURL { url in
                    if url.host == "chats" { model.goHome(.chats) }
                    if url.host == "inbox" { model.checkInbox() }
                }
        }
    }
}
