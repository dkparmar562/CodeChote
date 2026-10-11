#!/usr/bin/env bash
# A local SSH "host" for testing the app in the simulator, kept entirely inside .build/testhost:
#   - sshd on 127.0.0.1:2222 (user-level, key auth only)
#   - a fake `claude` CLI that speaks Claude Code's stream-json format, with an isolated config dir
#   - a small git repository with changes (.build/testrepo)
#   scripts/testhost.sh [start|stop|reset]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
H="$ROOT/.build/testhost"
REPO="$ROOT/.build/testrepo"
mkdir -p "$H/bin" "$H/server-home" "$H/claude-home" "$H/codex-home"

stop() { [ -f "$H/sshd.pid" ] && kill "$(cat "$H/sshd.pid")" 2>/dev/null || true; pkill -f "sshd -D -e -f $H/sshd_config" 2>/dev/null || true; }

make_fixtures() {
  # Keys
  [ -f "$H/host_ed25519" ] || ssh-keygen -q -t ed25519 -N "" -f "$H/host_ed25519"
  [ -f "$H/client_ed25519" ] || ssh-keygen -q -t ed25519 -N "" -f "$H/client_ed25519"
  cp "$H/client_ed25519.pub" "$H/authorized_keys"; chmod 600 "$H/authorized_keys" "$H/client_ed25519" "$H/host_ed25519"

  # sshd (the SetEnv lines point the app's agent adapters at the fakes below)
  cat > "$H/sshd_config" <<CONF
Port 2222
ListenAddress 127.0.0.1
HostKey $H/host_ed25519
PidFile $H/sshd.pid
AuthorizedKeysFile $H/authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
StrictModes no
AllowTcpForwarding yes
Subsystem sftp /usr/libexec/sftp-server
LogLevel INFO
SetEnv CLAUDE_USAGE_URL=http://127.0.0.1:8765/usage CODECHOTE_BIN_GEMINI=$H/bin/gemini CODECHOTE_BIN_AGY=$H/bin/agy CODECHOTE_HOME=$H/server-home CLAUDE_CONFIG_DIR=$H/claude-home CLAUDE_BIN=$H/bin/claude CODEX_HOME=$H/codex-home
CONF

  # Fake Claude Code
  cat > "$H/bin/claude" <<'MOCK'
#!/usr/bin/env bash
# Pretends to be `claude -p --output-format stream-json`. Reads the prompt on stdin: plain text, or with
# `--input-format stream-json` one JSON user message per line, the later ones answered after the first turn.
sid=""
all="$*"
while [ $# -gt 0 ]; do case "$1" in --resume) sid="$2"; shift 2;; *) shift;; esac; done
txt() { python3 -c 'import json,sys; m=json.loads(sys.stdin.read()); print("".join(c.get("text","") for c in m["message"]["content"]))'; }
stream=0
if printf %s "$all" | grep -q -- '--input-format'; then
  stream=1; IFS= read -r first || true; prompt="$(printf %s "$first" | txt)"
else
  prompt="$(cat)"
fi
[ -n "$sid" ] || sid="$(uuidgen | tr 'A-Z' 'a-z')"
turn="$(uuidgen | cut -c1-8)"   # message ids are unique per turn, as in Claude Code
enc="$(pwd | sed 's/[\/._]/-/g')"
dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/$enc"; mkdir -p "$dir"; f="$dir/$sid.jsonl"
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
j() { printf '%s\n' "$1"; }
esc() { python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'; }
p="$(printf %s "$prompt" | esc)"
printf '%s\n' "{\"type\":\"user\",\"cwd\":\"$(pwd)\",\"sessionId\":\"$sid\",\"timestamp\":\"$(ts)\",\"message\":{\"role\":\"user\",\"content\":$p}}" >> "$f"
j "{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"$sid\",\"cwd\":\"$(pwd)\",\"model\":\"mock\"}"
for w in "Let me " "take a look " "at the project " "first."; do
  j "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"$w\"}}}"; sleep 0.25
done
a1="{\"type\":\"assistant\",\"message\":{\"id\":\"msg_$sid-$turn-1\",\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"Let me take a look at the project first.\"}]},\"session_id\":\"$sid\"}"
j "$a1"; printf '%s\n' "$a1" >> "$f"
a2="{\"type\":\"assistant\",\"message\":{\"id\":\"msg_$sid-$turn-2\",\"role\":\"assistant\",\"content\":[{\"type\":\"tool_use\",\"id\":\"toolu_$sid\",\"name\":\"Bash\",\"input\":{\"command\":\"ls -la\",\"description\":\"List files\"}}]},\"session_id\":\"$sid\"}"
j "$a2"; printf '%s\n' "$a2" >> "$f"; sleep 0.6
listing="$(ls -la | head -8 | esc)"
u="{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"toolu_$sid\",\"content\":$listing,\"is_error\":false}]},\"session_id\":\"$sid\"}"
j "$u"; printf '%s\n' "$u" >> "$f"
for w in "## Summary\n\n" "This folder holds a small project.\n" "- **greet.swift**: greeting helpers\n" "- **README.md**: docs\n"; do
  j "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"$w\"}}}"; sleep 0.25
done
final='## Summary\n\nThis folder holds a small project:\n\n- **greet.swift**: greeting helpers\n- **README.md**: docs\n\nTry it:\n\n```swift\nprint(greet(\"world\"))\n```\n\nYou said: '
a3="{\"type\":\"assistant\",\"message\":{\"id\":\"msg_$sid-$turn-3\",\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"${final}$(printf %s "$prompt" | head -c 80 | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read())[1:-1])')\"}]},\"session_id\":\"$sid\"}"
j "$a3"; printf '%s\n' "$a3" >> "$f"
# "go slow": a long turn, for testing a connection that drops mid-turn.
case "$prompt" in *"go slow"*) sleep 12;; esac
# Scenarios, picked by words in the prompt, for testing the app's approval, question and plan cards.
denials="[]"
case "$prompt" in
  *"needs approval"*|"Approved."*)
    if printf %s "$all" | grep -q -- '--allowedTools'; then
      a4="{\"type\":\"assistant\",\"message\":{\"id\":\"msg_$sid-$turn-4\",\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"Thanks. Installed the packages and cleaned the build folder.\"}]},\"session_id\":\"$sid\"}"
      j "$a4"; printf '%s\n' "$a4" >> "$f"
    else
      t="{\"type\":\"assistant\",\"message\":{\"id\":\"msg_$sid-$turn-5\",\"role\":\"assistant\",\"content\":[{\"type\":\"tool_use\",\"id\":\"toolu_n$sid\",\"name\":\"Bash\",\"input\":{\"command\":\"npm install\"}},{\"type\":\"tool_use\",\"id\":\"toolu_r$sid\",\"name\":\"Bash\",\"input\":{\"command\":\"rm -rf build\"}}]},\"session_id\":\"$sid\"}"
      j "$t"; printf '%s\n' "$t" >> "$f"
      for id in "toolu_n$sid" "toolu_r$sid"; do
        r="{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"$id\",\"content\":\"Claude requested permissions to use Bash, but you haven't granted it yet.\",\"is_error\":true}]},\"session_id\":\"$sid\"}"
        j "$r"; printf '%s\n' "$r" >> "$f"
      done
      denials="[{\"tool_name\":\"Bash\",\"tool_use_id\":\"toolu_n$sid\",\"tool_input\":{\"command\":\"npm install\"}},{\"tool_name\":\"Bash\",\"tool_use_id\":\"toolu_r$sid\",\"tool_input\":{\"command\":\"rm -rf build\"}}]"
    fi ;;
  *"ask me"*)
    q="{\"type\":\"assistant\",\"message\":{\"id\":\"msg_$sid-$turn-6\",\"role\":\"assistant\",\"content\":[{\"type\":\"tool_use\",\"id\":\"toolu_q$sid\",\"name\":\"AskUserQuestion\",\"input\":{\"questions\":[{\"question\":\"Which test framework should I use?\",\"header\":\"Framework\",\"multiSelect\":false,\"options\":[{\"label\":\"XCTest\",\"description\":\"Built in, works everywhere\"},{\"label\":\"Swift Testing\",\"description\":\"Newer, macro based\"}]}]}}]},\"session_id\":\"$sid\"}"
    j "$q"; printf '%s\n' "$q" >> "$f" ;;
  *"show files"*)
    readme="$(cat -n README.md 2>/dev/null | sed 's/^ *\([0-9]*\)\t/     \1→/' | esc)"
    rd="{\"type\":\"assistant\",\"message\":{\"id\":\"msg_$sid-$turn-8\",\"role\":\"assistant\",\"content\":[{\"type\":\"tool_use\",\"id\":\"toolu_rd$sid\",\"name\":\"Read\",\"input\":{\"file_path\":\"$(pwd)/README.md\"}},{\"type\":\"tool_use\",\"id\":\"toolu_ed$sid\",\"name\":\"Edit\",\"input\":{\"file_path\":\"$(pwd)/greet.swift\",\"old_string\":\"func greet(_ name: String) -> String {\\n    \\\"Hello, \\\\(name)\\\"\\n}\",\"new_string\":\"/// Greets someone by name.\\nfunc greet(_ name: String) -> String {\\n    \\\"Hello, \\\\(name)!\\\"\\n}\"}}]},\"session_id\":\"$sid\"}"
    j "$rd"; printf '%s\n' "$rd" >> "$f"
    r1="{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"toolu_rd$sid\",\"content\":$readme,\"is_error\":false},{\"type\":\"tool_result\",\"tool_use_id\":\"toolu_ed$sid\",\"content\":\"The file has been updated.\",\"is_error\":false}]},\"session_id\":\"$sid\"}"
    j "$r1"; printf '%s\n' "$r1" >> "$f" ;;
  *"start server"*)
    sv="{\"type\":\"assistant\",\"message\":{\"id\":\"msg_$sid-$turn-10\",\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"The dev server is running. Open http://localhost:8790 to see it, or the API at \`localhost:8790/data.json\`.\"}]},\"session_id\":\"$sid\"}"
    j "$sv"; printf '%s\n' "$sv" >> "$f" ;;
  *"show table"*)
    tbtext=$'Here is how the agents compare:\n\n| Agent | Install | Streams input | Notes |\n|:------|:--------|:-------------:|------:|\n| **Claude Code** | `curl -fsSL https://claude.ai/install.sh \\| bash` | yes | Reads follow-ups mid-turn and survives dropped connections |\n| Codex | npm | no | 12 |\n| Gemini | npm | no | 3 |\n\nThat is all.'
    tb="{\"type\":\"assistant\",\"message\":{\"id\":\"msg_$sid-$turn-9\",\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":$(printf %s "$tbtext" | esc)}]},\"session_id\":\"$sid\"}"
    j "$tb"; printf '%s\n' "$tb" >> "$f" ;;
  *"make a plan"*)
    pl="{\"type\":\"assistant\",\"message\":{\"id\":\"msg_$sid-$turn-7\",\"role\":\"assistant\",\"content\":[{\"type\":\"tool_use\",\"id\":\"toolu_p$sid\",\"name\":\"ExitPlanMode\",\"input\":{\"plan\":\"## Plan\\n\\n1. Add **shout()** tests\\n2. Run the test suite\\n3. Update the README\"}}]},\"session_id\":\"$sid\"}"
    j "$pl"; printf '%s\n' "$pl" >> "$f" ;;
esac
j "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"session_id\":\"$sid\",\"result\":\"done\",\"total_cost_usd\":0.0123,\"duration_ms\":4200,\"num_turns\":3,\"usage\":{\"input_tokens\":1200,\"output_tokens\":340,\"cache_read_input_tokens\":8000},\"permission_denials\":$denials}"
n=10
while [ "$stream" = 1 ] && IFS= read -r line; do
  n=$((n+1)); more="$(printf %s "$line" | txt)"
  printf '%s\n' "{\"type\":\"user\",\"cwd\":\"$(pwd)\",\"sessionId\":\"$sid\",\"timestamp\":\"$(ts)\",\"message\":{\"role\":\"user\",\"content\":$(printf %s "$more" | esc)}}" >> "$f"
  sleep 1
  a="{\"type\":\"assistant\",\"message\":{\"id\":\"msg_$sid-$turn-$n\",\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":$(printf 'Got your follow-up: %s' "$more" | esc)}]},\"session_id\":\"$sid\"}"
  j "$a"; printf '%s\n' "$a" >> "$f"
  j "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"session_id\":\"$sid\",\"result\":\"done\",\"duration_ms\":1000,\"num_turns\":1,\"usage\":{\"input_tokens\":10,\"output_tokens\":5},\"permission_denials\":[]}"
done
MOCK
  chmod +x "$H/bin/claude"
  # A stand-in for a plain-text agent CLI (Gemini): prints what it was asked and the flags it got.
  cat > "$H/bin/gemini" <<'MOCK'
#!/bin/sh
printf '\033[32mHello from fake gemini\033[0m\n'
printf 'args: %s\n' "$*" | cut -c1-300
MOCK
  chmod +x "$H/bin/gemini"
  # A stand-in for Antigravity's agy: like the real one, it prints nothing unless it has a terminal.
  cat > "$H/bin/agy" <<'MOCK'
#!/bin/sh
[ -t 1 ] || exit 0
printf 'Hello from fake agy (with a terminal)\n'
printf 'args: %s\n' "$*" | cut -c1-200
MOCK
  chmod +x "$H/bin/agy"

  # Seed conversations in the fake config dir
  seed() { # folder id title
    local dir="$H/claude-home/projects/$(echo "$1" | sed 's/[\/._]/-/g')"; mkdir -p "$dir"
    printf '%s\n' "{\"type\":\"user\",\"cwd\":\"$1\",\"sessionId\":\"$2\",\"message\":{\"role\":\"user\",\"content\":\"$3\"}}" \
      "{\"type\":\"assistant\",\"message\":{\"id\":\"m-$2\",\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"Sure. Here is how I would approach that: start by reading the entry point, then trace the data flow.\"}]}}" > "$dir/$2.jsonl"
  }
  seed "$REPO" "11111111-1111-4111-8111-111111111111" "Explain how the greeting code works"
  seed "$REPO" "22222222-2222-4222-8222-222222222222" "Add a unit test for shout()"
  seed "$ROOT" "33333333-3333-4333-8333-333333333333" "Why does the terminal tab reconnect slowly?"
  touch -t 202601010000 "$H/claude-home/projects/"*"/33333333-3333-4333-8333-333333333333.jsonl"

  # A repo with history and pending changes
  rm -rf "$REPO"; mkdir -p "$REPO"; cd "$REPO"
  git init -q -b main; git config user.email t@example.com; git config user.name "Test User"
  printf 'import Foundation\n\nfunc greet(_ name: String) -> String {\n    return "Hello, \\(name)"\n}\n' > greet.swift
  printf '# Demo\n\nA tiny repo.\n' > README.md
  git add -A; git commit -qm "Initial commit"
  printf 'func farewell() {}\n' > bye.swift; git add bye.swift; git commit -qm "Add farewell"
  printf 'import Foundation\n\nfunc greet(_ name: String) -> String {\n    return "Hi there, \\(name)!"\n}\n\nfunc shout(_ s: String) -> String { s.uppercased() }\n' > greet.swift
  printf '# Demo\n\nA tiny repo that now has more lines.\n' > README.md; git add README.md
  printf 'new file\n' > notes.txt
}

case "${1:-start}" in
  stop) stop ;;
  reset) stop; rm -rf "$H/claude-home"; mkdir -p "$H/claude-home"; make_fixtures; (nohup /usr/sbin/sshd -D -e -f "$H/sshd_config" > "$H/sshd.log" 2>&1 &); sleep 1; echo "test host reset and running on 127.0.0.1:2222" ;;
  start) stop; make_fixtures; (nohup /usr/sbin/sshd -D -e -f "$H/sshd_config" > "$H/sshd.log" 2>&1 &); sleep 1; echo "test host running on 127.0.0.1:2222 (key: $H/client_ed25519)" ;;
esac
