# Finds an agent's command-line tool. $Agent: 'claude' or 'codex'. Prints its path, or nothing.
$candidates = @()
if ($Agent -eq 'claude') {
    $candidates += $env:CLAUDE_BIN
    $candidates += "$env:USERPROFILE\.claude\local\claude.exe", "$env:USERPROFILE\.local\bin\claude.exe", "$env:APPDATA\npm\claude.cmd"
    $candidates += (Get-ChildItem "$env:USERPROFILE\.vscode-server\extensions\anthropic.claude-code-*\resources\native-binary\claude.exe" -ErrorAction SilentlyContinue | Sort-Object FullName | Select-Object -Last 1 -ExpandProperty FullName)
} else {
    $candidates += $env:CODEX_BIN
    $candidates += "$env:APPDATA\npm\codex.cmd", "$env:USERPROFILE\.local\bin\codex.exe"
    $candidates += (Get-ChildItem "$env:USERPROFILE\.vscode-server\extensions\openai.chatgpt-*\bin\*\codex.exe" -ErrorAction SilentlyContinue | Sort-Object FullName | Select-Object -Last 1 -ExpandProperty FullName)
}
foreach ($c in $candidates) { if ($c -and (Test-Path -LiteralPath $c)) { ($c -replace '\\', '/'); return } }
$cmd = Get-Command $Agent -ErrorAction SilentlyContinue | Select-Object -First 1
if ($cmd) { ($cmd.Source -replace '\\', '/') }
