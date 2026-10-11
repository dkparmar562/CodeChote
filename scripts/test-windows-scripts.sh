#!/usr/bin/env bash
# Runs the Windows host scripts (ios/WindowsScripts/*.ps1) with PowerShell on this machine and checks their
# output. PowerShell 7 runs the same scripts the app sends to Windows PowerShell 5.1, with POSIX paths here.
#   brew install powershell   then   scripts/test-windows-scripts.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$ROOT/ios/WindowsScripts"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
pass=0; fail=0
# grep that reads all of its input (grep -q exits early, which pipefail reports as a failure)
has() { grep -- "$1" >/dev/null; }
check() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok   $1"; else fail=$((fail+1)); echo "  FAIL $1: expected [$2] got [$3]"; fi; }
ps() { pwsh -NoProfile -Command "$1" 2>&1; }
# The app wraps every script so errors arrive as a plain message (see PS.compose).
psw() { pwsh -NoProfile -Command "\$ErrorActionPreference='Stop'; try { $1 } catch { [Console]::Error.WriteLine(\$_.Exception.Message); exit 1 }" 2>&1 || true; }

mkdir -p "$W/proj/sub"; echo "hello" > "$W/proj/a.txt"; : > "$W/proj/.hidden"

echo "list"
out="$(ps "\$Path='$W/proj'; . $T/list.ps1")"
check "first line is the folder" "$W/proj" "$(echo "$out" | sed -n 1p)"
check "folders end in /"        "sub/" "$(echo "$out" | grep '^sub/$')"
check "files have no slash"     "a.txt" "$(echo "$out" | grep '^a.txt$')"
check "hidden files are listed" ".hidden" "$(echo "$out" | grep '^\.hidden$')"

echo "read / append"
check "read" "hello" "$(ps "\$Path='$W/proj/a.txt'; \$Limit=100; . $T/read.ps1" | base64 -d | tr -d '\n')"
ps "\$Path='$W/proj/b.txt'; \$Data='$(printf 'abc' | base64)'; \$Truncate='true'; . $T/append.ps1; \$Data='$(printf 'def' | base64)'; \$Truncate='false'; . $T/append.ps1" >/dev/null
check "chunked write" "abcdef" "$(cat "$W/proj/b.txt")"

echo "file operations"
ps "\$Op='createfile'; \$Path='$W/proj/new.txt'; . $T/fileops.ps1" >/dev/null; check "create file" "yes" "$([ -f "$W/proj/new.txt" ] && echo yes)"
check "create file twice fails" "yes" "$(psw "\$Op='createfile'; \$Path='$W/proj/new.txt'; . $T/fileops.ps1" | has 'Already exists' && echo yes)"
ps "\$Op='createfolder'; \$Path='$W/proj/x/y'; . $T/fileops.ps1" >/dev/null; check "create nested folder" "yes" "$([ -d "$W/proj/x/y" ] && echo yes)"
ps "\$Op='rename'; \$Path='$W/proj/new.txt'; \$Dest='$W/proj/renamed.txt'; . $T/fileops.ps1" >/dev/null; check "rename" "yes" "$([ -f "$W/proj/renamed.txt" ] && echo yes)"
check "rename onto existing fails" "yes" "$(psw "\$Op='rename'; \$Path='$W/proj/renamed.txt'; \$Dest='$W/proj/a.txt'; . $T/fileops.ps1" | has 'already exists' && echo yes)"
ps "\$Op='replace'; \$Path='$W/proj/b.txt'; \$Dest='$W/proj/a.txt'; . $T/fileops.ps1" >/dev/null; check "replace" "abcdef" "$(cat "$W/proj/a.txt")"
ps "\$Op='delete'; \$Path='$W/proj/x'; . $T/fileops.ps1" >/dev/null; check "delete folder" "gone" "$([ -e "$W/proj/x" ] || echo gone)"

echo "agents"
mkdir -p "$W/claude/projects/-p"; printf '%s\n' '{"type":"user","cwd":"/p","message":{"role":"user","content":"Fix it"}}' > "$W/claude/projects/-p/abc.jsonl"
out="$(CLAUDE_CONFIG_DIR="$W/claude" ps "\$Agent='claude'; \$Folder=''; . $T/agent-sessions.ps1")"
check "sessions list a file"     "yes" "$(echo "$out" | has '^@@FILE .*abc.jsonl [0-9]*$' && echo yes)"
check "sessions include content" "yes" "$(echo "$out" | has 'Fix it' && echo yes)"
check "transcript" "yes" "$(CLAUDE_CONFIG_DIR="$W/claude" ps "\$Agent='claude'; \$SessionId='abc'; . $T/agent-transcript.ps1" | has 'Fix it' && echo yes)"
check "prompt is piped to the agent" "hello agent" "$(ps "\$Cwd='$W'; \$Exe='/bin/cat'; \$ArgList=@(); \$PromptB64='$(printf 'hello agent' | base64)'; . $T/agent-run.ps1" | tr -d '\r\n')"

echo "installer (dry run)"
mkdir -p "$W/home/server-abc/bin"; : > "$W/home/server-abc/bin/code-server.cmd"; echo '{"commit":"abc","quality":"stable"}' > "$W/home/server-abc/product.json"
out="$(CODECHOTE_HOME="$W/home" PROCESSOR_ARCHITECTURE=AMD64 ps "\$env:USERPROFILE='$W'; \$Pin='abc'; \$UrlTemplate='x'; \$DryRun='true'; . $T/bootstrap.ps1")"
check "reports arch, commit, quality" "yes" "$(echo "$out" | has 'DRYRUN x64 .* abc stable 48' && echo yes)"

echo; echo "$pass passed, $fail failed"; [ "$fail" = 0 ]
