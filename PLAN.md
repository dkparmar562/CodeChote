# Codechote: direction

An iPhone app for working with coding agents on your own machines (Linux, macOS or Windows) over SSH: like
Claude's mobile app, but for every coding agent, running on a remote host. Nothing is installed by hand on the host.

## How it is built

**Chats first, with native screens and the full VS Code alongside.** Chats, files, source control and the
terminal are native SwiftUI over plain SSH tools (`ls`, `git`, a shell, the agents' own CLIs), so they do not
depend on VS Code's internals. VS Code itself is available inside a project, for its editor and extensions.

```
iPhone                                             Host (Linux, macOS, Windows)
┌───────────────────────────────────────────┐      ┌──────────────────────────────┐
│ Projects │ Chats │ Settings   (home)       │      │ agent CLIs: claude, codex,   │
│  Chats ── one screen per conversation ──────────▶ │   cursor-agent, opencode, …  │
│  Project ── tabs:                          │      │ plain SSH: ls, git, shell    │
│   ├ Files, Editor, Source Control, Diff ─────────▶ │                              │
│   ├ Terminal (SwiftTerm, tmux) ──────────────────▶ │ ~/.codechote-server/<commit> │
│   ├ Browser (host's own addresses) ──────────────▶ │   VS Code server (stock)     │
│   ├ Remote screen (noVNC → VNC) ─────────────────▶ │ VNC server, if you run one   │
│   └ VS Code (WKWebView) ── SSH tunnel ───────────▶ │                              │
└───────────────────────────────────────────┘      └──────────────────────────────┘
```

* The VS Code UI ships **inside the app** and is served locally; only the server runs on the host.
* UI and server are the **same VS Code commit** (`workbench/VSCODE_REF`); the app installs exactly that server.
* Our changes to VS Code are a small patch (`workbench/patches/`), applied to a pinned checkout by
  `workbench/build.sh` (`task workbench:build`). VS Code is a side feature: nothing else depends on it.

## What exists

| Area | State |
|---|---|
| Home: **Projects** (hosts and their projects, add host, new project), **Chats** (default), **Settings** | done |
| Hosts: several connected at once; every saved host connects on launch and on return, quietly | done |
| Chats list: all agents, hosts and projects; quick project switcher; Now (working, needs you, active elsewhere); Today / Yesterday / 7 days / older; search; archive, rename, delete | done |
| Chat screen: full screen, swipe from the edge to go back; keeps running when you leave; picks up turns made in a terminal or VS Code | done |
| Fast history: lists and transcripts kept on the phone (read off the main thread), refreshed when the host's file changes; long chats load their newest part | done |
| Chat screen opens at the latest message with nothing blank or jumping; the latest 60 messages are drawn, "Show Earlier Messages" adds more in place; jump-to-latest button when scrolled up | done |
| Runs of tool calls fold into one "N steps" row (tools used, failures), the current step shown while the agent works | done |
| Markdown in replies: headings, lists, quotes, code with copy, tables (aligned columns, wrapping cells, sideways scroll) | done |
| Projects tell apart folders with the same name ("work/api", "home/api") and keep one colour each | done |
| Approvals (one card for several, allow all or one by one, always for this chat), questions with tappable answers, plans to approve, to-do checklists | done (Claude Code) |
| Notifications: finished, question, plan, approval; tapping opens that chat (also from a cold start) | done; local only |
| Send messages while the agent works (Claude Code reads them right away; other agents queue them); attach photos and files; copy, send again; tokens per turn | done |
| Agent runs survive dropped connections: they run detached on the host and the app picks up where it left off | done (Claude Code, Codex) |
| Keep the screen on while an agent or run is working (Settings); hide-keyboard buttons in chat, terminal and install sheet | done |
| Model and access level per agent and per chat; usage meters (opt-in) | done |
| Agent not installed: shows the install command, runs it in a terminal after you confirm | done |
| Agents: Claude Code, Codex (full); Cursor, OpenCode, Kilo, Gemini CLI, Copilot CLI, Antigravity (`agy -p`, run under a pseudo-terminal) (plain text, experimental) | as noted |
| Tool calls open full screen: files highlighted with line numbers, Markdown rendered (Preview/Source), edits as diffs, commands with output, images from the host | done |
| Pinned chats (top of All and of their project) | done |
| Changes per chat: files the agent touched, git diff each, revert, commit (and push), one section per repository (nested repos and ones outside the project) | done |
| Composer: `/` suggests Claude Code custom commands, `@` suggests project files | done |
| Run shortcuts per project (saved, or found: npm scripts, make, swift, cargo, go, pytest): live output, Stop, notification, "ask the agent to fix it" | done |
| Pull requests through `gh` on the host: list, description, checks, reviews, diff, comment / approve / request changes, check out, hand the feedback to an agent; installs or signs in gh when missing | done; not tried against GitHub |
| Live Activity (Lock Screen, Dynamic Island): agents working and waiting on you | done; updated while the app runs |
| Share extension: send photos, files, text or links from any app into a new chat | done; app group `group.dev.codechote.app` |
| Usage at the end of Chats: account for every installed agent; limits for Claude (5 hours, weekly), Codex, Copilot (premium requests) | done |
| Remote screen setup: one-tap command per system (macOS Screen Sharing, x11vnc, TightVNC) | done; not tried on a real desktop |
| Project tabs: Files, Editor, Source Control, Terminal, Browser, Remote screen, VS Code | done |
| Browser: a real browser whose host-side addresses (localhost, internal names, private and Tailscale networks) go through SSH via an in-app SOCKS proxy, public sites direct; links in chats open there; per-host cookies; "everything through the host" option | done |
| Files: search in files (opens at the line), upload photos and files, share a file from the phone, ask an agent about a file | done |
| Tests: unit, integration over SSH against the test host, end-to-end UI tests, performance; CI workflow | done; CI not yet run |
| Remote screen: noVNC in the app, VNC over SSH, touch controls, keys bar | works against a test VNC server; not tried on a real desktop |
| Windows hosts | scripts tested with PowerShell 7; not on a real PC |

## Known limits

* Notifications are local: iOS suspends the app soon after it leaves the screen, and push needs a paid Apple
  account, so a long reply that finishes after that is only noticed when you reopen the app.
* Approvals are after the fact: Claude Code stops when a tool is blocked; approving re-runs the turn with exactly
  that permission. A live mid-turn prompt would need an MCP permission-prompt tool on the host.
* Chats talk to each agent's CLI in headless mode. Codex has no approval prompts there. Cursor, OpenCode, Kilo,
  Gemini and Copilot reply in plain text and keep their history on the phone.
* Native chat reads each agent's session files and stream format; these are not public contracts. The adapters
  ignore what they don't recognise rather than failing.
* Switching to another project discards the previous project's tabs on screen (chats are not affected).
* Remote screen needs a VNC server on the host (Screen Sharing on macOS; TightVNC or similar on Windows;
  x11vnc or wayvnc on Linux). Windows' own Remote Desktop protocol is not supported.
* Plugin webviews and the VS Code tab need **iOS 26 or later**.
* Kilo Code and Antigravity icons are simple drawn marks, not official logos.
