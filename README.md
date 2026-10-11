# Codechote

An iPhone app for working with coding agents on your own machines. It's like Claude's mobile app, but for
every coding agent (Claude Code, Codex, Cursor, OpenCode, Kilo Code, Gemini CLI, Copilot CLI, Antigravity),
running on your hosts (Linux, macOS or Windows) over SSH. Nothing is installed by hand on a host: the app
uses the agents' own CLIs and plain shell tools.

Internal distribution only.

## Goals

* **Handle the whole development loop from an iPhone, without a laptop.** That means asking agents to do the
  work, then answering their questions and approvals, reviewing, committing and opening pull requests. It
  also means running the project and previewing it in a browser, using a terminal, and finding and changing
  files.
* **Any coding agent, on any machine you own.** The agents' own CLIs run on Linux, macOS or Windows (WSL
  too), reached over SSH. A host needs nothing beyond SSH and the agents you use; the app sets up anything
  else it needs there itself.
* **Chats first, and dependable.** Conversations open instantly and keep running while you're elsewhere in
  the app. They survive dropped connections, tell you when an agent needs you, and pick up turns made in a
  terminal or VS Code.
* **Native and phone-first.** SwiftUI and the system's own look, usable with one hand, quick to do the common
  things.
* **Your machines, your accounts.** Agents run with their own sign-ins on your hosts. The app has no server of
  its own, and nothing leaves your phone and hosts except what the agents themselves send.

## Non-goals

* **Not an AI agent or model provider.** The app drives the agents' CLIs; it doesn't run models, hold API keys or
  proxy requests to providers.
* **Not a hosted service.** There's no backend, account or sync server. That's also why notifications are local:
  push needs a server, and a paid Apple account.
* **Not a full IDE on a phone.** Focused native screens cover files, Git and the terminal. The VS Code workbench
  is there for the occasional job that needs it; it isn't the main way to work.
* **Not running code on the phone.** Everything runs on the hosts; the phone is the window onto them.
* **Not a general browser or remote-desktop client.** The browser and remote screen are for previewing and
  checking work on a host.
* **Not managing infrastructure.** The app doesn't create hosts, VPNs or tunnels. You reach hosts over SSH,
  through Tailscale or similar when they're not on a network the phone can see (see "Reaching your hosts").
* **Not on the App Store, and not for iPad or Mac (for now).** It's built for iPhone and installed directly.

## What it does

* **Chats** (the main screen): every conversation on every connected host, grouped by day, filtered by project.
  You can see which chats are working and which need you. Chats keep running when you leave them, and they
  survive dropped connections.
* **In a chat:** approvals, questions and plans as cards; messages sent while the agent works; photos and files;
  folded tool steps; full-screen tool details; and the changes per chat, with diff, revert and commit.
* **Projects:** hosts and their folders. Each project has tabs: Files, Source Control, Terminal, Browser
  (reaching the host's own addresses), Remote screen (VNC), and the full **VS Code** workbench as a side feature.
* **Around it:** notifications, a Live Activity, a share extension, run shortcuts, pull requests through `gh`,
  and usage and limits per agent account.

`PLAN.md` has the full feature list, the known limits and the direction.

## Getting started

Needs a Mac with Xcode 26 or later, and Homebrew. The commands are in `Taskfile.yml`
([Task](https://taskfile.dev): `brew install go-task`). Run `task` to list them.

```sh
task setup      # XcodeGen, the Metal toolchain SwiftTerm needs, the Xcode project; then a check of everything
task run        # starts the local test host and runs the app in the simulator, connected to it
task test       # unit tests
task install    # builds and installs on the connected iPhone (unlocked and trusted; run from Terminal.app)
```

| Command | What it does |
|---|---|
| `task doctor` | Checks Xcode, XcodeGen, the workbench bundle, the simulator, the test host and a connected iPhone |
| `task build` | Simulator build, prints only errors |
| `task run -- <options>` | Run in the simulator; options such as `-devOpenChat 0` or `-devHomeTab projects` (see `App/DevLaunch.swift`) |
| `task shot -- <options>` | The same, then saves a screenshot to `.build/shot.png` |
| `task logs` | Follows the app's console from the last run |
| `task test -- -only-testing:CodechoteTests/ChatItemTests` | One test suite |
| `task test:integration` | Unit tests plus integration tests over real SSH against the test host |
| `task test:ui` | End-to-end UI tests: the app driven against the test host |
| `task test:all` | Everything, including the Windows script checks when PowerShell is installed |
| `task host:start`, `host:stop`, `host:reset` | The local SSH test host |
| `task open` | Opens the project in Xcode |
| `task workbench:build` | Builds the VS Code workbench bundle (see below) |
| `task clean` | Removes build output |

`SIM="iPhone 18 Pro" task run` picks a simulator by name or UDID. By default the app runs on a booted iPhone
simulator, or the newest one.

## Layout

| Path | What it is |
|---|---|
| `ios/project.yml` | The Xcode project, generated by XcodeGen (`task gen`). The `.xcodeproj` isn't kept in git. |
| `ios/Codechote/App` | App entry, `AppModel` (hosts, projects, tabs), home screen, notifications, Live Activity, simulator launch options |
| `ios/Codechote/Chats` | Chats list, chat screen and its rows, `ChatModel` (one conversation), `ChatCenter` (all of them), approvals, changes, Markdown |
| `ios/Codechote/Agents` | `AgentKind`, the conversation model, one adapter per agent CLI, models, install, usage |
| `ios/Codechote/Hosts` | SSH (`SSHSession`), shell and files on the host, detached jobs (`HostJob`), host OS detection, saved hosts and keys |
| `ios/Codechote/Projects` | Projects screen and a project's tabs: Files, Editor, Git, pull requests, Terminal, Browser, Remote screen, run shortcuts |
| `ios/Codechote/Workbench` | The VS Code tab: the web view, the local server it loads from, the bridge, the host's server installer |
| `ios/Codechote/Settings` | Settings |
| `ios/Shared`, `ios/Widgets`, `ios/Share` | Code shared with the extensions, the Live Activity widget, the share extension |
| `ios/WindowsScripts` | PowerShell versions of the host commands, for Windows hosts |
| `ios/Resources` | noVNC, and the VS Code bundle (`vscode-web`, built by `task workbench:build`, not in git) |
| `ios/Tests` | Unit tests |
| `scripts/` | The test host, the icon generator, the Windows script checks |
| `workbench/` | The VS Code side: pinned commit, our patches, their build (see `workbench/README.md`) |
| `.build/` | Everything generated: builds, the VS Code checkout, the test host. Not in git. |

## Reaching your hosts

The app needs SSH to the host and nothing else. Behind a home router or NAT, the simplest way is
[Tailscale](https://tailscale.com): install it on the host and on the phone, then add the host in the app by its
Tailscale name (`my-box` or `my-box.tailnet-name.ts.net`) or its `100.x.y.z` address. A public IP, a VPN or
port forwarding work just as well.

The browser doesn't need Tailscale. Dev servers often listen only on the host's `localhost`, which Tailscale can't
reach, so the app takes the browser through SSH (see below).

## Hosts

| Host | Status | Notes |
|---|---|---|
| Linux | supported | `sh` tools, `tmux` for persistent terminals when present |
| macOS | supported | Needs macOS 12 or later for `sort -V`; older systems fall back |
| Windows 10/11 | supported, not tried on a real PC | Needs the OpenSSH Server feature. Runs everything as PowerShell |
| WSL | works as Linux | Run `sshd` inside WSL and connect to it like any Linux host |

**Windows setup (on the PC, in an administrator PowerShell):**

```powershell
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Start-Service sshd; Set-Service -Name sshd -StartupType Automatic
```

Sign in with a password, or with a key: add the public key to `%USERPROFILE%\.ssh\authorized_keys` (for
administrator accounts: `C:\ProgramData\ssh\administrators_authorized_keys`). Install Git for Windows for
Source Control, and the agent CLIs for chat.

How Windows differs: the app detects the OS on connect and runs the bundled PowerShell scripts instead of `sh`
commands. Paths stay in `C:/Users/me` form inside the app. There is no `tmux`, so a terminal does not survive a
dropped connection. `task test:windows` runs the scripts with PowerShell 7 on a Mac.

## Testing

| Layer | Where | Run with | What it covers |
|---|---|---|---|
| Unit | `ios/Tests` | `task test` | Parsers (agent streams, transcripts, git, diffs, grep), chat rows, Markdown, approvals, names, performance of long chats |
| Integration | `ios/Tests/Integration` | `task test:integration` | Real SSH to the test host: commands, file round trips, search, repositories, detached jobs, a whole Claude Code turn with a message sent mid-turn |
| UI (end to end) | `ios/UITests` | `task test:ui` | The app launched and tapped through: home screen, sending a message, approving commands, answering a question, approving a plan, settings |
| Windows scripts | `scripts/test-windows-scripts.sh` | `task test:windows` | The PowerShell host scripts, run with PowerShell 7 |
| CI | `.github/workflows/ci.yml` | every push and pull request | Build, then the unit, integration and UI tests on a macOS runner, with logs kept when something fails |

Integration and UI tests skip themselves when no test host is configured, so `task test` stays fast.

`task host:start` runs a local "host" inside `.build/testhost`:
* sshd on 127.0.0.1:2222, key only;
* fake `claude`, `gemini` and `agy` CLIs that speak the real formats;
* a sample git repository with changes, in `.build/testrepo`.

The fake Claude Code reacts to words in the prompt, to exercise each card: "needs approval", "ask me",
"make a plan", "show files", "show table", "go slow" (a long turn, to test dropped connections). It also
answers messages sent mid-turn.

`task run` / `task shot` connect the simulator to it. The launch options in `App/DevLaunch.swift` open
screens and send messages without tapping, for screenshots and checks.

## The VS Code workbench

A project's VS Code tab is the real VS Code web UI, shipped inside the app. Only the VS Code server runs on the
host; the app installs it there on first use. The UI and the server must be the same commit, which is pinned in
`workbench/VSCODE_REF`. Our changes (phone layout, native bridges) are one patch in `workbench/patches/`.
`task workbench:build` fetches that commit, applies the patch, and builds and copies the bundle into the app.
Details and upgrading: `workbench/README.md`.

## Browser

The browser (a project tab, the chat menu, or any host link tapped in a chat) works like a normal browser,
with one difference: the host's own addresses open as the host sees them.

* `localhost:3000`, plain names (`intranet`), `.local` / `.internal` / Tailscale names and private networks
  (10.x, 192.168.x, 172.16-31.x, 100.64-127.x) go through the host's SSH connection.
* Public sites (`youtube.com`, `github.com`) load straight from the phone. A bare name like `youtube.com` means
  its https site, and text that isn't an address is a web search.
* "Open Everything Through the Host" in its menu sends public sites through the host too. That's for sites only
  the host's network or VPN can reach.

Under the hood the web view uses a SOCKS proxy inside the app (like `ssh -D`), so pages keep their real
addresses. Host names, cookies, redirects and https all behave as usual. Self-signed certificates are
accepted for the host's own addresses only. Each host keeps its own cookies and site data.
