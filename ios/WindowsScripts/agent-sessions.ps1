# Lists an agent's saved conversations in the format the app already parses for Unix hosts.
# Variables: $Agent ('claude' | 'codex'), $Folder ('' = all projects; Claude only).
function Emit($file) {
    $unix = [DateTimeOffset]::new($file.LastWriteTimeUtc).ToUnixTimeSeconds()
    "@@FILE $($file.FullName -replace '\\','/') $unix"
    Get-Content -LiteralPath $file.FullName -TotalCount 40 -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.Length -gt 3000) { $_.Substring(0, 3000) } else { $_ }
    }
}
if ($Agent -eq 'claude') {
    $root = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.claude' }
    $projects = Join-Path $root 'projects'
    $pattern = if ($Folder) { Join-Path $projects (($Folder -replace '[^A-Za-z0-9]', '-')) } else { Join-Path $projects '*' }
    Get-ChildItem -Path (Join-Path $pattern '*.jsonl') -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 60 | ForEach-Object { Emit $_ }
} else {
    $root = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
    Get-ChildItem -Path (Join-Path $root 'sessions') -Recurse -Filter 'rollout-*.jsonl' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 50 | ForEach-Object { Emit $_ }
}
