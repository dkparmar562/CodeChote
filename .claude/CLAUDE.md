# Codechote

An iPhone app (SwiftUI, iOS 26+) for chatting with coding agents (Claude Code, Codex, Cursor, OpenCode, Kilo,
Gemini CLI, Copilot CLI, Antigravity) that run on the user's own hosts over SSH. Chats are the product. Projects
(Files, Git, Terminal, Browser, Remote screen) support them, and the VS Code workbench is a side feature.
Internal distribution only. `README.md` covers the layout; `PLAN.md` covers features, limits and direction.

## Where things are

- `ios/Codechote/{App,Chats,Agents,Hosts,Projects,Workbench,Settings}` are the feature folders (see README).
- `ios/project.yml` is the XcodeGen project. After adding, moving or deleting a Swift file, run `task gen`.
  Sources are picked up by folder.
- `workbench/` holds the VS Code side (pinned commit plus one patch). The VS Code source isn't in this repo;
  `task workbench:build` fetches it into `.build/`.
- Everything generated goes in `.build/`. Don't write outside the repository.

## Commands (`Taskfile.yml`)

- `task build`: simulator build, errors only. `task test`: unit tests
   (`task test -- -only-testing:CodechoteTests/<Suite>` for one suite). `task test:integration` adds the tests
  over real SSH against the test host, and `task test:ui` runs the end-to-end UI tests (`ios/UITests`). Add an
  integration or UI test for any new host-side or end-to-end behaviour.
- `task host:start`, then `task shot -- <launch options>` builds, runs against the local test host and saves
  `.build/shot.png`. Read the screenshot to check UI changes. The launch options are in `App/DevLaunch.swift`.
- `task install` puts the app on the connected iPhone. It fails while the Mac's login keychain is locked (codesign);
  say so rather than retrying in a loop.
- `scripts/testhost.sh` defines the fake agents. Prompt words pick scenarios ("needs approval", "ask me",
  "make a plan", "show files", "show table", "go slow").

## Code

- Swift with 4-space indentation, matching the files around it. Add `///` doc comments on types and on anything
  non-obvious. Comments explain why, briefly.
- State lives in `@Observable` `@MainActor` models (`AppModel`, `ChatCenter`, `ChatModel`). Views stay thin.
  Heavy work (parsing transcripts, cache encode and decode) runs off the main actor.
- Everything on a host goes through `SSHSession` (`exec`, `execLines`), within its concurrency gate. Each host
  command has a PowerShell twin for Windows hosts (`ios/WindowsScripts`).
- Agent CLIs are reached through `AgentAdapter` implementations in `Agents/`. Their output formats aren't
  public contracts, so ignore what isn't recognised rather than failing.
- User-facing text is plain English: short sentences, no jargon. Buttons and menu items use title case
  ("Show Earlier Messages"). Errors say what happened and what to do (see `describeError`).
- Prefer native SwiftUI controls and system styles. Keep the chat screen fast: rows are `Equatable`, Markdown
  parsing is cached, and only the latest messages are drawn.
- Add tests next to similar ones in `ios/Tests`. Prefer one `XCTAssertEqual` on a whole result over many small
  assertions.
- Verify changes yourself (build, tests, simulator screenshots) before reporting. Report what was and wasn't
  verified.
