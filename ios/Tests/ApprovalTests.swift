import XCTest
@testable import Codechote

final class ApprovalTests: XCTestCase {
    func testParsesDeniedToolCalls() {
        let denials: [[String: Any]] = [
            ["tool_name": "Bash", "tool_use_id": "t1", "tool_input": ["command": "npm install"]],
            ["tool_name": "Edit", "tool_use_id": "t2", "tool_input": ["file_path": "/p/a.swift"]],
        ]
        let requests = PermissionRequest.parse(denials)
        XCTAssertEqual(requests.map(\.rule), ["Bash(npm install)", "Edit"])
        XCTAssertEqual(requests.first?.summary, "npm install")
        XCTAssertEqual(requests.last?.summary, "a.swift")
    }

    func testIgnoresMissingOrMalformedDenials() {
        XCTAssertTrue(PermissionRequest.parse(nil).isEmpty)
        XCTAssertTrue(PermissionRequest.parse("nope").isEmpty)
        XCTAssertTrue(PermissionRequest.parse([["tool_use_id": "x"]]).isEmpty)
    }
}

final class AgentPromptTests: XCTestCase {
    func testQuestionsWithOptions() {
        let json = #"{"questions":[{"question":"Which database?","header":"Database","multiSelect":false,"options":[{"label":"Postgres","description":"Relational"},{"label":"SQLite"}]},{"question":"Extras?","header":"Extras","multiSelect":true,"options":[{"label":"Auth"}]}]}"#
        let questions = QuestionPrompt.parse(inputJSON: json)
        XCTAssertEqual(questions.count, 2)
        XCTAssertEqual(questions[0].options.map(\.label), ["Postgres", "SQLite"])
        XCTAssertEqual(questions[0].options[0].detail, "Relational")
        XCTAssertTrue(questions[1].multiSelect)
        XCTAssertTrue(QuestionPrompt.parse(inputJSON: "not json").isEmpty)
    }

    func testPlanAndTodos() {
        XCTAssertEqual(PlanPrompt.parse(id: "p", inputJSON: #"{"plan":"1. Do it"}"#)?.plan, "1. Do it")
        XCTAssertNil(PlanPrompt.parse(id: "p", inputJSON: "{}"))
        let todos = TodoItem.parse(inputJSON: #"{"todos":[{"content":"Write","status":"completed"},{"content":"Test","status":"in_progress","activeForm":"Testing"},{"content":"Ship","status":"pending"}]}"#)
        XCTAssertEqual(todos.map(\.status), [.done, .active, .pending])
        XCTAssertEqual(todos[1].text, "Testing")
    }

    func testTurnOutcomeNoticesQuestionsAndPlans() {
        let user = ChatMessage(id: "u", role: .user, blocks: [.text("go")])
        let plan = ToolCall(id: "1", name: "ExitPlanMode", inputJSON: "{}", summary: "")
        let question = ToolCall(id: "2", name: "AskUserQuestion", inputJSON: "{}", summary: "")
        let planTurn = [user, ChatMessage(id: "a", role: .assistant, blocks: [.tool(plan)])]
        let questionTurn = [user, ChatMessage(id: "b", role: .assistant, blocks: [.tool(question)])]
        if case .hasQuestion = TurnOutcome.from(messages: planTurn, error: nil) {} else { XCTFail("plan should ask for approval") }
        if case .hasQuestion = TurnOutcome.from(messages: questionTurn, error: nil) {} else { XCTFail("question should be noticed") }
    }
}
