import XCTest

/// The app driven as a person would, against the local test host (`task test:ui` starts it). Each test launches
/// the app connected to the host, does one job, and checks what is on screen. The fake Claude Code on the host picks
/// its behaviour from words in the message (see scripts/testhost.sh).
final class ChatFlowUITests: XCTestCase {
    private var home = ""
    private var repo = ""

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard let path = ProcessInfo.processInfo.environment["CODECHOTE_TESTHOST"], !path.isEmpty else {
            throw XCTSkip("No test host configured (run with task test:ui).")
        }
        home = path
        repo = (path as NSString).deletingLastPathComponent + "/testrepo"
    }

    private func launch(_ arguments: [String] = []) -> XCUIApplication {
        let user = ProcessInfo.processInfo.environment["CODECHOTE_TESTHOST_USER"] ?? NSUserName()
        let app = XCUIApplication()
        app.launchArguments = ["-devSSH", "127.0.0.1:2222:\(user):\(home)/client_ed25519"] + arguments
        app.launch()
        return app
    }

    /// A new Claude Code chat in the test repository.
    private func newChat() -> XCUIApplication {
        launch(["-devNewChat", "claude", "-devChatFolder", repo])
    }

    private func send(_ text: String, in app: XCUIApplication) {
        // A multi-line text field is a text view to the accessibility tree.
        let box = app.descendants(matching: .any).matching(identifier: "Message Claude Code").firstMatch
        let field = box.exists ? box : app.textViews.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20), "No message box")
        field.tap()
        field.typeText(text)
        app.buttons["Send"].tap()
    }

    private func text(_ fragment: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", fragment)).firstMatch
    }

    func testChatsIsTheHomeScreen() {
        let app = launch()
        XCTAssertTrue(app.navigationBars["Chats"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["Projects"].exists)
        XCTAssertTrue(app.buttons["Settings"].exists)
    }

    func testSendingAMessageGetsAReply() {
        let app = newChat()
        send("hello from the ui test", in: app)
        XCTAssertTrue(text("You said: hello from the ui test", in: app).waitForExistence(timeout: 40))
    }

    func testApprovingBlockedCommandsLetsTheAgentFinish() {
        let app = newChat()
        send("needs approval please", in: app)
        let allowAll = app.buttons["Allow All"]
        XCTAssertTrue(allowAll.waitForExistence(timeout: 40), "No approval card")
        allowAll.tap()
        XCTAssertTrue(text("Installed the packages", in: app).waitForExistence(timeout: 40))
    }

    /// One question with one choice: tapping the answer sends it.
    func testAnsweringAQuestion() {
        let app = newChat()
        send("ask me please", in: app)
        let option = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "XCTest")).firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 40), "No question card")
        option.tap()
        XCTAssertTrue(text("You said: Framework: XCTest", in: app).waitForExistence(timeout: 40))
    }

    func testApprovingAPlan() {
        let app = newChat()
        send("make a plan please", in: app)
        let approve = app.buttons["Approve and Start"]
        XCTAssertTrue(approve.waitForExistence(timeout: 40), "No plan card")
        approve.tap()
        XCTAssertTrue(text("You said: The plan is approved", in: app).waitForExistence(timeout: 40))
    }

    func testSettingsShowsTheAgentsAndOptions() {
        let app = launch()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 20))
        app.buttons["Settings"].tap()
        let agent = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Claude Code")).firstMatch
        XCTAssertTrue(agent.waitForExistence(timeout: 10), "Buttons: \(app.buttons.allElementsBoundByIndex.map(\.label))")
        // Settings is a list: rows further down only exist once scrolled to.
        let keepAwake = app.switches["Keep Screen On While Working"]
        for _ in 0..<6 where !keepAwake.exists { app.swipeUp() }
        XCTAssertTrue(keepAwake.exists)
    }
}
