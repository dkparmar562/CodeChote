import XCTest
@testable import Codechote

final class ChatCenterTests: XCTestCase {
    func testChatKeysMatchAcrossDraftAndSession() {
        let host = UUID()
        var draft = ChatKey(draft: .claude, hostID: host, folder: "/p")
        let sameDraft = draft
        XCTAssertTrue(draft.id.hasPrefix("draft|"))
        draft.sessionID = "abc"
        XCTAssertEqual(draft.id, ChatKey.id(hostID: host, agent: .claude, sessionID: "abc"))
        XCTAssertNotEqual(draft, sameDraft)
    }

    func testTranscriptCacheRoundTrip() {
        let id = "test-\(UUID().uuidString)"
        let call = ToolCall(id: "1", name: "Bash", inputJSON: "{}", summary: "ls", result: "ok")
        let messages = [
            ChatMessage(id: "u", role: .user, blocks: [.text("hi")]),
            ChatMessage(id: "a", role: .assistant, blocks: [.thinking("hmm"), .tool(call), .text("done")]),
        ]
        ChatCache.saveTranscript(id, messages: messages, signature: "10 20")
        let loaded = ChatCache.transcript(id)
        XCTAssertEqual(loaded?.messages, messages)
        XCTAssertEqual(loaded?.signature, "10 20")
        ChatCache.removeTranscript(id)
        XCTAssertNil(ChatCache.transcript(id))
    }

    func testTurnStatsSummary() {
        let stats = TurnStats.parse(["usage": ["input_tokens": 1200, "output_tokens": 300, "cache_read_input_tokens": 8000], "total_cost_usd": 0.0123, "duration_ms": 4200, "num_turns": 3])
        XCTAssertEqual(stats?.summary, "3 steps · 9.5K tokens · 4 s")
        XCTAssertNil(TurnStats.parse([:]))
    }

    func testShortAges() {
        let now = Date()
        XCTAssertEqual(ChatRow.age(now.addingTimeInterval(-20), now: now), "now")
        XCTAssertEqual(ChatRow.age(now.addingTimeInterval(-600), now: now), "10m")
        XCTAssertEqual(ChatRow.age(now.addingTimeInterval(-7200), now: now), "2h")
        XCTAssertEqual(ChatRow.age(now.addingTimeInterval(-3 * 86400), now: now), "3d")
    }

    func testCopilotQuota() {
        let json = #"{"login":"octocat","quota_reset_date":"2026-11-01","quota_snapshots":{"premium_interactions":{"entitlement":300,"remaining":225,"unlimited":false},"chat":{"unlimited":true}}}"#
        let report = UsageReader.parseCopilot(json)
        XCTAssertEqual(report?.account, "octocat")
        XCTAssertEqual(report?.meters.count, 1)
        XCTAssertEqual(report?.meters.first?.detail, "75 of 300")
        XCTAssertEqual(report?.meters.first?.fraction ?? 0, 0.25, accuracy: 0.001)
        XCTAssertNotNil(report?.meters.first?.resetsAt)
    }

    func testPlainTextForCopying() {
        let message = ChatMessage(id: "a", role: .assistant, blocks: [.text("one"), .thinking("x"), .text("two")])
        XCTAssertEqual(message.plainText, "one\n\ntwo")
    }
}

final class ChatItemTests: XCTestCase {
    private func tool(_ id: String, _ name: String) -> ChatBlock { .tool(ToolCall(id: id, name: name, inputJSON: "{}", summary: "", result: "ok")) }

    private func describe(_ items: [ChatItem]) -> [String] {
        items.map { item in
            let end = item.endOf.map { " end:\($0)" } ?? ""
            switch item.kind {
            case .user(let message): return "user \(message.id)\(end)"
            case .text(let text): return "text \(text)\(end)"
            case .thinking: return "thinking\(end)"
            case .tools(let calls): return "tools \(calls.map(\.id).joined(separator: ","))\(end)"
            }
        }
    }

    func testRunsOfToolCallsFoldTogetherAcrossMessages() {
        let messages: [ChatMessage] = [
            ChatMessage(id: "u1", role: .user, blocks: [.text("fix it")]),
            ChatMessage(id: "a1", role: .assistant, blocks: [.text("Looking."), tool("t1", "Read")]),
            ChatMessage(id: "a2", role: .assistant, blocks: [tool("t2", "Bash")]),
            ChatMessage(id: "a3", role: .assistant, blocks: [tool("t3", "TodoWrite"), tool("t4", "Edit"), .text("Done.")]),
        ]
        XCTAssertEqual(describe(ChatItem.items(from: messages[...])), [
            "user u1 end:u1",
            "text Looking.",
            "tools t1,t2 end:a2",
            "tools t3",
            "tools t4",
            "text Done. end:a3",
        ])
    }
}

final class ProjectNameTests: XCTestCase {
    func testClashingProjectNamesGetTheirParentFolder() {
        let names = ProjectPill.names(for: ["/Users/me/work/api", "/Users/me/home/api", "/Users/me/app", "/Users/me/work/api"])
        XCTAssertEqual(names, ["/Users/me/work/api": "work/api", "/Users/me/home/api": "home/api", "/Users/me/app": "app"])
    }
}

/// Keeps long chats fast: these run on every redraw of the chat screen.
final class ChatPerformanceTests: XCTestCase {
    private func longChat(_ count: Int) -> [ChatMessage] {
        (0..<count).map { index in
            index % 3 == 0
                ? ChatMessage(id: "u\(index)", role: .user, blocks: [.text("Step \(index): fix module \(index)")])
                : ChatMessage(id: "a\(index)", role: .assistant, blocks: [
                    .text("Looking at module \(index)."),
                    .tool(ToolCall(id: "t\(index)", name: "Read", inputJSON: "{\"file_path\":\"/p/m\(index).swift\"}", summary: "m\(index).swift", result: "ok")),
                ])
        }
    }

    func testFoldingALongChatIntoRows() {
        let messages = longChat(3000)
        measure { _ = ChatItem.items(from: messages[...]) }
    }

    func testParsingALongReply() {
        let reply = (0..<200).map { "## Part \($0)\n\nSome **bold** text with `code` and a [link](https://example.com).\n\n- one\n- two\n\n| a | b |\n|---|---|\n| 1 | 2 |\n" }.joined(separator: "\n")
        measure { _ = MDBlock.parse(reply) }
    }
}
