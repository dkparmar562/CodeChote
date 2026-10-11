# Prints one conversation's file (its last 6 MB). Variables: $Agent, $SessionId.
if ($Agent -eq 'claude') {
    $root = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.claude' }
    $file = Get-ChildItem -LiteralPath (Join-Path $root 'projects') -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { Join-Path $_.FullName "$SessionId.jsonl" } |
        Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1 | ForEach-Object { Get-Item -LiteralPath $_ }
} else {
    $root = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
    $file = Get-ChildItem -LiteralPath (Join-Path $root 'sessions') -Recurse -Filter "*$SessionId*.jsonl" -ErrorAction SilentlyContinue | Select-Object -First 1
}
if ($file) {
    $fs = [IO.File]::Open($file.FullName, 'Open', 'Read', 'ReadWrite')
    try {
        # The newest part of a long conversation matters most: read the end (a cut first line is skipped).
        $length = [int][Math]::Min($fs.Length, 6000000)
        [void]$fs.Seek($fs.Length - $length, 'Begin')
        $buffer = New-Object byte[] $length
        $read = $fs.Read($buffer, 0, $length)
        [Console]::Out.Write([Text.Encoding]::UTF8.GetString($buffer, 0, $read))
    } finally { $fs.Dispose() }
}
