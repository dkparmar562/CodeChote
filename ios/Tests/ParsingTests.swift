import XCTest
import NIOCore
import SwiftUI
@testable import Codechote

final class DiffParserTests: XCTestCase {
    func testLineNumbersAndKinds() {
        let diff = """
        diff --git a/greet.swift b/greet.swift
        index 111..222 100644
        --- a/greet.swift
        +++ b/greet.swift
        @@ -3,4 +3,5 @@ func greet
         func greet() {
        -    return "Hello"
        +    return "Hi"
        +    // extra
         }
        """
        let lines = DiffParser.parse(diff)
        XCTAssertEqual(lines.first?.kind, .file)
        XCTAssertEqual(lines.first?.text, "greet.swift")
        XCTAssertEqual(lines.filter { $0.kind == .added }.count, 2)
        XCTAssertEqual(lines.filter { $0.kind == .removed }.count, 1)
        let removed = lines.first { $0.kind == .removed }
        XCTAssertEqual(removed?.oldNumber, 4)
        let added = lines.filter { $0.kind == .added }
        XCTAssertEqual(added.map(\.newNumber), [4, 5])
    }

    func testEmptyDiff() { XCTAssertTrue(DiffParser.parse("").isEmpty) }
}

final class GitStatusTests: XCTestCase {
    func testBranchAheadBehindAndAreas() {
        let output = """
        ## main...origin/main [ahead 2, behind 1]
        M  staged.swift
         M changed.swift
        MM both.swift
        ?? new.txt
        R  old.swift -> renamed.swift
        UU conflict.swift
        """
        let status = GitModel.parseStatus(output)
        XCTAssertEqual(status.branch, "main")
        XCTAssertEqual(status.upstream, "origin/main")
        XCTAssertEqual(status.ahead, 2)
        XCTAssertEqual(status.behind, 1)
        XCTAssertEqual(status.staged.map(\.path).sorted(), ["both.swift", "renamed.swift", "staged.swift"])
        XCTAssertEqual(status.unstaged.map(\.path).sorted(), ["both.swift", "changed.swift"])
        XCTAssertEqual(status.untracked.map(\.path), ["new.txt"])
        XCTAssertEqual(status.conflicts.map(\.path), ["conflict.swift"])
        XCTAssertEqual(status.staged.first { $0.path == "renamed.swift" }?.origPath, "old.swift")
    }

    func testNoUpstreamAndNoCommits() {
        XCTAssertNil(GitModel.parseStatus("## feature").upstream)
        XCTAssertEqual(GitModel.parseStatus("## No commits yet on main").branch, "main")
    }
}

final class MarkdownTests: XCTestCase {
    func testBlocks() {
        let blocks = MDBlock.parse("# Title\n\nSome **text**.\n\n- one\n- two\n\n1. first\n2. second\n\n```swift\nlet x = 1\n```\n")
        var kinds: [String] = []
        for block in blocks {
            switch block {
            case .heading(let level, _): kinds.append("h\(level)")
            case .paragraph: kinds.append("p")
            case .bullets(let items): kinds.append("b\(items.count)")
            case .numbered(let items): kinds.append("n\(items.count)")
            case .code(let lang, let code): kinds.append("code:\(lang ?? "")=\(code)")
            default: kinds.append("other")
            }
        }
        XCTAssertEqual(kinds, ["h1", "p", "b2", "n2", "code:swift=let x = 1"])
    }

    func testUnterminatedFenceWhileStreaming() {
        let blocks = MDBlock.parse("```py\nprint(1)")
        guard case .code(_, let code)? = blocks.first else { return XCTFail("expected a code block") }
        XCTAssertEqual(code, "print(1)")
    }
}

final class AgentParsingTests: XCTestCase {
    func testClaudeEncodesFolders() {
        XCTAssertEqual(ClaudeAdapter.encode(folder: "/Users/me/my_proj.v2"), "-Users-me-my-proj-v2")
    }

    func testSessionListingUsesSummaryThenFirstUserText() {
        let listing = """
        @@FILE /h/.claude/projects/-p/aaa.jsonl 1700000100
        {"type":"user","cwd":"/p","message":{"role":"user","content":"Fix the login bug"}}
        {"type":"summary","summary":"Login bug fix"}
        @@FILE /h/.claude/projects/-p/bbb.jsonl 1700000200
        {"type":"user","cwd":"/p","message":{"role":"user","content":"<command-name>/clear</command-name>"}}
        {"type":"user","cwd":"/p","message":{"role":"user","content":[{"type":"text","text":"Add tests"}]}}
        """
        let sessions = ClaudeAdapter.parseListing(listing)
        XCTAssertEqual(sessions.map(\.id), ["bbb", "aaa"])          // newest first
        XCTAssertEqual(sessions.map(\.title), ["Add tests", "Login bug fix"])
        XCTAssertEqual(sessions.first?.folder, "/p")
    }

    func testAssemblerMergesBlocksAndAttachesToolResults() {
        var assembler = MessageAssembler()
        let lines = [
            #"{"type":"user","message":{"role":"user","content":"List files"}}"#,
            #"{"type":"assistant","message":{"id":"m1","role":"assistant","content":[{"type":"text","text":"Sure."}]}}"#,
            #"{"type":"assistant","message":{"id":"m1","role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}]}}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"a\nb","is_error":false}]}}"#,
        ]
        for line in lines { assembler.consume(AgentJSON.object(line)!) }
        XCTAssertEqual(assembler.messages.count, 2)                // the prompt, and one merged assistant message
        guard case .tool(let call)? = assembler.messages[1].blocks.last else { return XCTFail("expected a tool call") }
        XCTAssertEqual(call.name, "Bash")
        XCTAssertEqual(call.summary, "ls")
        XCTAssertEqual(call.result, "a\nb")
    }

    func testCodexRequestIsExtractedFromIDEContext() {
        let wrapped = "# Context from my IDE setup:\n## Open tabs: a.swift\n\n## My request for Codex:\nFix the crash"
        XCTAssertEqual(AgentJSON.userRequest(from: wrapped), "Fix the crash")
        XCTAssertEqual(AgentJSON.userRequest(from: "plain"), "plain")
    }
}

@MainActor
final class TabsTests: XCTestCase {
    private func makeModel() -> TabsModel {
        let key = "test-\(UUID().uuidString)"
        return TabsModel(profileKey: key)
    }

    func testSingletonsAreReusedAndOthersRepeat() {
        let tabs = makeModel()
        let first = tabs.open(.files)
        let again = tabs.open(.files)
        XCTAssertEqual(first.id, again.id)
        tabs.open(.terminal)
        tabs.open(.terminal)
        XCTAssertEqual(tabs.tabs.filter { $0.kind == .terminal }.count, 2)
    }

    func testSameConversationAndFileAreNotDuplicated() {
        let tabs = makeModel()
        tabs.open(.chat(agent: .claude, session: "abc"))
        tabs.open(.chat(agent: .claude, session: "abc"))
        tabs.open(.chat(agent: .claude, session: nil))
        tabs.open(.chat(agent: .claude, session: nil))
        tabs.open(.file(path: "/a/b.swift"))
        tabs.open(.file(path: "/a/b.swift"))
        XCTAssertEqual(tabs.tabs.count, 4)   // one "abc", two new chats, one file
    }

    func testClosingSelectsNeighbourAndSteppingStopsAtTheEnds() {
        let tabs = makeModel()
        let a = tabs.open(.files), b = tabs.open(.git), c = tabs.open(.terminal)
        XCTAssertFalse(tabs.step(1))                   // already on the last tab: no wrap, like the iOS switcher
        XCTAssertEqual(tabs.selectedID, c.id)
        XCTAssertTrue(tabs.step(-1))
        XCTAssertEqual(tabs.selectedID, b.id)
        tabs.select(a.id)
        XCTAssertFalse(tabs.step(-1))
        tabs.select(b.id)
        tabs.close(b.id)
        XCTAssertEqual(tabs.selectedID, c.id)          // the tab that took its place
        XCTAssertEqual(tabs.tabs.count, 2)
    }

    func testNewChatBecomesSpecificOnceTheAgentReportsItsSession() {
        let tabs = makeModel()
        let tab = tabs.open(.chat(agent: .claude, session: nil))
        tabs.bind(tab.id, toSession: "xyz")
        XCTAssertEqual(tabs.tabs.first?.kind, .chat(agent: .claude, session: "xyz"))
    }

    func testTabsSurviveARestart() {
        let key = "test-\(UUID().uuidString)"
        let tabs = TabsModel(profileKey: key)
        tabs.open(.files); tabs.open(.terminal)
        let restored = TabsModel(profileKey: key)
        XCTAssertEqual(restored.tabs.map(\.kind), [.files, .terminal])
    }
}

final class MiscTests: XCTestCase {
    func testCSSColors() {
        XCTAssertNotNil(Color(css: "#1e1e1e"))
        XCTAssertNotNil(Color(css: "#fff"))
        XCTAssertNotNil(Color(css: "rgb(31, 31, 31)"))
        XCTAssertNil(Color(css: "not a color"))
    }

    func testShellQuoting() {
        XCTAssertEqual(shellQuote("a b"), "'a b'")
        XCTAssertEqual(shellQuote("it's"), "'it'\\''s'")
    }

    func testMimeTypesForTheBundledUI() {
        XCTAssertEqual(WorkbenchRouter.mimeType(for: "x/y.js"), "text/javascript; charset=utf-8")
        XCTAssertEqual(WorkbenchRouter.mimeType(for: "x/y.wasm"), "application/wasm")
        XCTAssertEqual(WorkbenchRouter.mimeType(for: "x/y.woff2"), "font/woff2")
    }

    func testInstallerScriptPinsTheServerCommit() {
        let script = RemoteServerInstaller.script(downloadURL: RemoteServerInstaller.downloadURL(forCommit: "abc123"), commit: "abc123")
        XCTAssertTrue(script.contains("commit:abc123/server-@OS@-@ARCH@-web"))
        XCTAssertTrue(script.contains("PIN=\"abc123\""))
    }

    func testPrivateKeysSurviveTrailingNewlines() {
        // The SSH library rejects keys with stray whitespace; the app normalises them first.
        let raw = "-----BEGIN OPENSSH PRIVATE KEY-----\r\nAAAA\r\n-----END OPENSSH PRIVATE KEY-----\r\n"
        let cleaned = raw.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
        XCTAssertTrue(cleaned.hasSuffix("-----END OPENSSH PRIVATE KEY-----"))
    }
}

final class WindowsHostTests: XCTestCase {
    func testPathsConvertBetweenNativeAndVSCodeForms() {
        XCTAssertEqual(HostPath.toWorkbench("C:/Users/me/proj", windows: true), "/c:/Users/me/proj")
        XCTAssertEqual(HostPath.fromWorkbench("/c:/Users/me/proj", windows: true), "C:/Users/me/proj")
        XCTAssertEqual(HostPath.toWorkbench("/home/me", windows: false), "/home/me")     // other hosts are untouched
        XCTAssertEqual(HostPath.fromWorkbench("/home/me", windows: true), "/home/me")
    }

    func testJoiningAndParentsOnWindows() {
        XCTAssertEqual(HostPath.join("C:/Users", "me", windows: true), "C:/Users/me")
        XCTAssertEqual(HostPath.join("C:/", "Users", windows: true), "C:/Users")
        XCTAssertEqual(HostPath.join(HostPath.drives, "D:", windows: true), "D:/")        // from the drive list
        XCTAssertEqual(HostPath.parent("C:/Users/me", windows: true), "C:/Users")
        XCTAssertEqual(HostPath.parent("C:/Users", windows: true), "C:/")
        XCTAssertEqual(HostPath.parent("C:/", windows: true), HostPath.drives)
        XCTAssertEqual(HostPath.lastComponent("C:/"), "C:")
        XCTAssertEqual(HostPath.lastComponent("C:/Users/me"), "me")
    }

    func testJoiningAndParentsOnUnix() {
        XCTAssertEqual(HostPath.join("/", "usr", windows: false), "/usr")
        XCTAssertEqual(HostPath.parent("/usr", windows: false), "/")
        XCTAssertEqual(HostPath.parent("/home/me", windows: false), "/home")
    }

    func testPowerShellQuotingDoublesQuotes() {
        XCTAssertEqual(PS.quote("it's"), "'it''s'")
        XCTAssertEqual(PS.quote("C:/My Files"), "'C:/My Files'")
    }

    func testComposedScriptsAssignVariablesAndReportErrorsCleanly() {
        let script = PS.compose("Write-Output $Path", vars: ["Path": .string("C:/a b"), "ArgList": .array(["-p", "x y"])])
        XCTAssertTrue(script.contains("$Path = 'C:/a b'"))
        XCTAssertTrue(script.contains("$ArgList = @('-p', 'x y')"))
        XCTAssertTrue(script.contains("catch"))
        XCTAssertTrue(script.contains("[Console]::Error.WriteLine"))
        XCTAssertFalse(script.contains("Remove-Item -LiteralPath $PSCommandPath"))
        XCTAssertTrue(PS.compose("x", selfDelete: true).contains("Remove-Item -LiteralPath $PSCommandPath"))
    }

    func testEncodedCommandIsUTF16Base64() {
        let command = PS.encodedCommand("echo hi")
        let b64 = String(command.split(separator: " ").last!)
        let data = Data(base64Encoded: b64)!
        XCTAssertEqual(String(data: data, encoding: .utf16LittleEndian), "echo hi")
        XCTAssertTrue(command.hasPrefix("powershell -NoProfile"))
    }

    func testDirectoryOutputParsingHandlesWindowsListings() {
        let folder = SSHSession.parseDirectoryOutput("C:/Users/me\r\nDocuments/\r\nnotes.txt\r\n.ssh/\r\n")
        XCTAssertEqual(folder?.path, "C:/Users/me")
        XCTAssertEqual(folder?.entries.map(\.name), [".ssh", "Documents", "notes.txt"])
        XCTAssertEqual(folder?.entries.map(\.isDirectory), [true, true, false])
        let drives = SSHSession.parseDirectoryOutput("\nC:/\nD:/\n")
        XCTAssertEqual(drives?.path, "")
        XCTAssertEqual(drives?.entries.map(\.name), ["C:", "D:"])
    }

    func testClaudeProjectFolderNamesMatchBothPlatforms() {
        XCTAssertEqual(ClaudeAdapter.encode(folder: "C:/Users/me/proj"), "C--Users-me-proj")
        XCTAssertEqual(ClaudeAdapter.encode(folder: "/Users/me/proj"), "-Users-me-proj")
    }

    func testEveryWindowsScriptIsBundled() {
        for name in ["list", "read", "append", "fileops", "home", "bootstrap", "agent-locate", "agent-sessions", "agent-transcript", "agent-run"] {
            XCTAssertFalse(PS.loadScript(name).contains("Missing script"), "\(name).ps1 is not in the app bundle")
        }
    }
}

final class UsageTests: XCTestCase {
    func testCodexRateLimits() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let line = #"{"timestamp":"1970-01-12T13:46:40Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":42.5,"window_minutes":300,"resets_at":1003600},"secondary":{"used_percent":80,"window_minutes":10080,"resets_at":999000}}}}"#
        let report = UsageReader.parseCodexRateLimits(line, now: now)
        XCTAssertEqual(report?.meters.count, 2)
        XCTAssertEqual(report?.meters[0].label, "5 hours")
        XCTAssertEqual(report?.meters[0].fraction ?? 0, 0.425, accuracy: 0.001)
        XCTAssertNotNil(report?.meters[0].resetsAt)
        // The weekly window had already reset, so nothing is used.
        XCTAssertEqual(report?.meters[1].label, "Weekly")
        XCTAssertEqual(report?.meters[1].fraction, 0)
    }

    func testClaudePlanUsage() {
        let json = #"{"five_hour":{"utilization":37.0,"resets_at":"2099-01-01T00:00:00.000Z"},"seven_day":{"utilization":91,"resets_at":null}}"#
        let report = UsageReader.parseClaudePlan(json)
        XCTAssertEqual(report?.meters.map(\.label), ["Session (5 hours)", "Weekly"])
        XCTAssertEqual(report?.meters[1].fraction ?? 0, 0.91, accuracy: 0.001)
        XCTAssertNil(UsageReader.parseClaudePlan("not json"))
    }

    func testTokenWindows() {
        let now = UsageReader.parseDate("2026-01-10T12:00:00Z")!
        let output = "2026-01-10T11:00:00.000Z 1000 500\n2026-01-08T00:00:00Z 2000 1000\n2025-12-01T00:00:00Z 9 9\nbroken line\n"
        let counts = UsageReader.tokenWindows(from: output, now: now)
        XCTAssertEqual(counts.fiveHours, "1.5K tokens")
        XCTAssertEqual(counts.week, "4.5K tokens")
    }

    func testProviderTiers() {
        XCTAssertEqual(AgentKind.chatKinds.count, 8)
        XCTAssertEqual(AgentKind.cursor.command, "cursor-agent")
        XCTAssertEqual(AgentKind.antigravity.command, "agy")
        XCTAssertTrue(AgentKind.antigravity.needsTerminal)
        for agent in AgentKind.allCases { XCTAssertFalse(agent.title.isEmpty) }
    }
}

final class TurnOutcomeTests: XCTestCase {
    private func assistant(_ blocks: [ChatBlock]) -> ChatMessage { ChatMessage(id: UUID().uuidString, role: .assistant, blocks: blocks) }
    private let user = ChatMessage(id: "u", role: .user, blocks: [.text("go")])

    func testFinishedAndQuestion() {
        XCTAssertEqual(TurnOutcome.from(messages: [user, assistant([.text("All done.")])], error: nil), .finished(preview: "All done."))
        XCTAssertEqual(TurnOutcome.from(messages: [user, assistant([.text("Which file?")])], error: nil), .hasQuestion(preview: "Which file?"))
    }

    func testPermissionBlockWinsAndOldTurnsAreIgnored() {
        var call = ToolCall(id: "1", name: "Bash", inputJSON: "{}", summary: "rm")
        call.result = "Claude requested permissions to use Bash, but you haven't granted it yet."; call.isError = true
        XCTAssertEqual(TurnOutcome.from(messages: [user, assistant([.tool(call)]), assistant([.text("I couldn't run it.")])], error: nil), .needsPermission)
        // The same error in an earlier turn doesn't count.
        XCTAssertEqual(TurnOutcome.from(messages: [assistant([.tool(call)]), user, assistant([.text("Fine.")])], error: nil), .finished(preview: "Fine."))
    }

    func testErrorWins() {
        XCTAssertEqual(TurnOutcome.from(messages: [user], error: "boom"), .failed("boom"))
    }
}

final class CLIChatTests: XCTestCase {
    func testPromptCarriesHistory() {
        let history = [LocalChatStore.Turn(role: "user", text: "hi"), LocalChatStore.Turn(role: "assistant", text: "hello")]
        let prompt = CLIChatAdapter.composePrompt(history: history, prompt: "next", readOnly: false)
        XCTAssertTrue(prompt.contains("User: hi") && prompt.contains("Assistant: hello") && prompt.hasSuffix("next"))
        XCTAssertEqual(CLIChatAdapter.composePrompt(history: [], prompt: "only", readOnly: false), "only")
        XCTAssertTrue(CLIChatAdapter.composePrompt(history: [], prompt: "x", readOnly: true).hasPrefix("Plan only"))
    }

    func testCleaningTerminalOutput() {
        XCTAssertEqual(CLIChatAdapter.clean("\u{1B}[32mgreen\u{1B}[0m"), "green")
        XCTAssertEqual(CLIChatAdapter.clean("loading\rdone"), "done")
    }

    func testArgumentsPutPromptLast() {
        XCTAssertEqual(CLIChatAdapter(kind: .gemini).arguments(mode: .bypass), ["--yolo", "-p"])
        XCTAssertEqual(CLIChatAdapter(kind: .opencode).arguments(mode: .acceptEdits), ["run"])
        XCTAssertEqual(CLIChatAdapter(kind: .opencode).arguments(mode: .acceptEdits, model: "a/b"), ["run", "-m", "a/b"])
        XCTAssertEqual(AgentKind.claude.modelArguments("opus"), ["--model", "opus"])
        XCTAssertEqual(AgentKind.claude.modelArguments(""), [])
        XCTAssertEqual(CLIChatAdapter(kind: .antigravity).arguments(mode: .bypass), ["--dangerously-skip-permissions", "-p"])
    }
}

final class BrowserTargetTests: XCTestCase {
    func testAddressesGoThroughTheHostUnlessPublicHTTPS() {
        let dev = BrowserTarget.parse("localhost:3000/app?x=1")
        XCTAssertEqual(dev?.host, "localhost"); XCTAssertEqual(dev?.effectivePort, 3000); XCTAssertEqual(dev?.path, "/app?x=1"); XCTAssertEqual(dev?.viaHost, true)
        // Through the host: its own addresses, plain names, private networks (Tailscale's too). Public sites: the phone.
        let routes = ["192.168.1.5:8080", "https://intranet/wiki", "app.internal", "100.101.2.3:3000", "box.tail1234.ts.net", "10.0.0.2",
                      "https://example.com/docs", "http://example.com", "youtube.com", "8.8.8.8", "172.32.0.1"]
            .map { BrowserTarget.parse($0)?.viaHost ?? false }
        XCTAssertEqual(routes, [true, true, true, true, true, true, false, false, false, false, false])
        // A bare public name is the https site; the host's own addresses stay http.
        XCTAssertEqual(["youtube.com", "localhost:3000", "intranet", "http://example.com"].map { BrowserTarget.parse($0)?.url?.absoluteString },
                       ["https://youtube.com/", "http://localhost:3000/", "http://intranet/", "http://example.com/"])
        XCTAssertNil(BrowserTarget.parse("not an address"))
        XCTAssertNil(BrowserTarget.parse(""))
    }

    func testListeningPortsFromEachTool() {
        let ss = "LISTEN 0 4096 127.0.0.1:3000 0.0.0.0:*\nLISTEN 0 128 0.0.0.0:22 0.0.0.0:*\nLISTEN 0 511 [::]:5173 [::]:*\nLISTEN 0 5 127.0.0.1:41234 0.0.0.0:*\n"
        XCTAssertEqual(BrowserTarget.listeningPorts(in: ss), [3000, 5173])
        let lsof = "node 1 me 20u IPv4 0x1 0t0 TCP *:8080 (LISTEN)\n"
        XCTAssertEqual(BrowserTarget.listeningPorts(in: lsof), [8080])
        let mac = "tcp4 0 0 *.9229 *.* LISTEN\n"
        XCTAssertEqual(BrowserTarget.listeningPorts(in: mac, excluding: [9229]), [])
        XCTAssertEqual(BrowserTarget.listeningPorts(in: "TCP 0.0.0.0:3001 0.0.0.0:0 LISTENING\n"), [3001])
    }

    func testMarkdownTables() {
        let text = "Intro\n\n| Agent | Install | Count |\n|:--|:-:|--:|\n| **Claude** | `a \\| b` | 12 |\n| Codex | npm |\nAfter"
        let blocks = MDBlock.parse(text)
        guard blocks.count == 3, case .table(let table) = blocks[1] else { return XCTFail("\(blocks.map(\.id))") }
        XCTAssertEqual(table, MDTable(header: ["Agent", "Install", "Count"], alignments: [.leading, .center, .trailing],
                                      rows: [["**Claude**", "`a | b`", "12"], ["Codex", "npm", ""]]))
        // A pipe in a sentence, with no separator row after it, stays a paragraph.
        guard case .paragraph = MDBlock.parse("use a | b here\nnext line").first else { return XCTFail() }
    }

    func testRepoDiscoveryGroupsFilesByRepository() {
        let output = "R\t/p\nR\t/p/libs/b\nR\t/p\nF\t/p/libs/b\tsrc/z.c\nF\t/p\tREADME.md\nF\t/other\tx.swift\n"
        let found = RepoDiscovery.parse(output)
        XCTAssertEqual(found, RepoDiscovery.Found(repos: ["/p", "/p/libs/b", "/other"],
                                                  files: ["/p/libs/b": ["src/z.c"], "/p": ["README.md"], "/other": ["x.swift"]]))
    }
}

final class ErrorTextTests: XCTestCase {
    private struct Failure: LocalizedError { let errorDescription: String? }

    func testConnectionErrorsReadPlainly() {
        let raw = [
            "Connection errors: SingleConnectionFailure(error: connection reset (error set): Connection refused) (errno: 61))",
            "NIOSSHError(type: tcpShutdown)",
            "Operation timed out",
        ]
        XCTAssertEqual(raw.map { describeError(Failure(errorDescription: $0)) }, [
            "The host refused the connection. Check that SSH is running on it.",
            "The connection to the host dropped. It reconnects on its own; try again in a moment.",
            "The host didn't answer in time. Check the network.",
        ])
    }
}

final class LinkifyTests: XCTestCase {
    func testPlainAddressesBecomeLinks() {
        let text = MarkdownView.attributed("Open http://localhost:5173/app, or `localhost:3000`. Served on 0.0.0.0:8080; see [docs](https://example.com) and port 22.")
        let links = text.runs.compactMap { run in run.link.map { "\(String(text[run.range].characters)) -> \($0.absoluteString)" } }
        XCTAssertEqual(links, [
            "http://localhost:5173/app -> http://localhost:5173/app",
            "localhost:3000 -> http://localhost:3000",
            "0.0.0.0:8080 -> http://localhost:8080",
            "docs -> https://example.com",
        ])
    }
}

final class ProjectSearchTests: XCTestCase {
    func testGrepOutputBecomesMatches() {
        let output = "src/app.swift:12:    let x = greet(\"a\")\n./notes/todo.md:3:greet everyone\nweird:name.txt:7:greet: yes\nnot a match\n"
        XCTAssertEqual(ProjectSearch.parse(output), [
            SearchMatch(path: "src/app.swift", line: 12, text: "let x = greet(\"a\")"),
            SearchMatch(path: "notes/todo.md", line: 3, text: "greet everyone"),
            SearchMatch(path: "weird:name.txt", line: 7, text: "greet: yes"),
        ])
    }

    func testUploadNamesStayUnique() {
        let taken: Set<String> = ["photo.jpg", "photo 2.jpg", "notes"]
        XCTAssertEqual(["photo.jpg", "notes", "new.txt"].map { FileTransfer.uniqueName($0, taken: taken) }, ["photo 3.jpg", "notes 2", "new.txt"])
    }

    func testLineRanges() {
        let text = "one\ntwo\nthree" as NSString
        XCTAssertEqual([1, 2, 3, 9].map { text.substring(with: CodeTextView.range(ofLine: $0, in: text)) }, ["one", "two", "three", "three"])
    }
}

final class SocksRequestTests: XCTestCase {
    private func buffer(_ bytes: [UInt8]) -> ByteBuffer { ByteBuffer(bytes: bytes) }

    func testConnectRequestsForEachAddressType() {
        let name = Array("localhost".utf8)
        let requests: [[UInt8]] = [
            [5, 1, 0, 3, UInt8(name.count)] + name + [0x0B, 0xB8],          // localhost:3000
            [5, 1, 0, 1, 192, 168, 1, 5, 0x1F, 0x90],                       // 192.168.1.5:8080
            [5, 1, 0, 4] + [UInt8](repeating: 0, count: 15) + [1, 0, 80],   // [::1]:80
            [5, 1, 0, 3, 20, 0x61],                                         // incomplete
        ]
        let parsed = requests.map { SocksHandler.parseRequest(buffer($0)).map { "\($0.host) \($0.port) \($0.length)" } ?? "incomplete" }
        XCTAssertEqual(parsed, ["localhost 3000 16", "192.168.1.5 8080 10", "::1 80 22", "incomplete"])
    }
}
