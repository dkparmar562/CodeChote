# Installs (first time) and starts the pinned VS Code server on a Windows host, or reuses a running one.
# Variables set by the app: $Pin (commit; '' = latest), $UrlTemplate (with @OS@ and @ARCH@), $DryRun ('true' only in tests).
# Output protocol is the same as the Unix script: CODECHOTE_STATUS / _ERR / _PRODUCT / _READY lines.
function Say($text) { [Console]::Out.WriteLine($text); [Console]::Out.Flush() }
function Fail($text) { Say "CODECHOTE_ERR $text"; exit 1 }

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$D = if ($env:CODECHOTE_HOME) { $env:CODECHOTE_HOME } else { Join-Path $env:USERPROFILE '.codechote-server' }
New-Item -ItemType Directory -Force -Path $D | Out-Null

$arch = switch ($env:PROCESSOR_ARCHITECTURE) { 'ARM64' { 'arm64' } 'AMD64' { 'x64' } default { '' } }
if (-not $arch) { Fail "unsupported architecture $($env:PROCESSOR_ARCHITECTURE)" }

$envFile = Join-Path $D 'server.env'
$productFile = Join-Path $D 'product.json'

function Test-Port($port) {
    try { $c = New-Object Net.Sockets.TcpClient; $c.Connect('127.0.0.1', [int]$port); $c.Close(); return $true } catch { return $false }
}
function Product-Line() { 'CODECHOTE_PRODUCT ' + [Convert]::ToBase64String([IO.File]::ReadAllBytes($productFile)) }

# Reuse a server that is still running, if it is the right version.
if (Test-Path $envFile) {
    $saved = @{}
    Get-Content $envFile | ForEach-Object { $k, $v = $_ -split '=', 2; if ($k) { $saved[$k] = $v } }
    $alive = $saved['PID'] -and (Get-Process -Id ([int]$saved['PID']) -ErrorAction SilentlyContinue)
    $right = $saved['COMMIT'] -and ((-not $Pin) -or ($saved['COMMIT'] -eq $Pin))
    if ($alive -and $right -and (Test-Path $productFile) -and (Test-Port $saved['PORT'])) {
        Say (Product-Line)
        Say "CODECHOTE_READY $($saved['PORT']) $($saved['TOKEN']) $($saved['COMMIT']) $($saved['QUALITY'])"
        return
    }
    if ($saved['PID']) { Stop-Process -Id ([int]$saved['PID']) -Force -ErrorAction SilentlyContinue }
}

$sdir = if ($Pin) { Join-Path $D "server-$Pin" } else { Join-Path $D 'server' }
$launcher = Join-Path $sdir 'bin\code-server.cmd'

if (-not (Test-Path $launcher)) {
    Say 'CODECHOTE_STATUS Downloading server (windows)'
    $url = $UrlTemplate.Replace('@OS@', 'win32').Replace('@ARCH@', $arch)
    $zip = Join-Path $D 'server.zip'
    Remove-Item $zip -Force -ErrorAction SilentlyContinue
    try { Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $zip } catch { Fail "download failed: $($_.Exception.Message) ($url)" }
    Say 'CODECHOTE_STATUS Unpacking'
    $tmp = Join-Path $D 'server.tmp'
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    try { Expand-Archive -LiteralPath $zip -DestinationPath $tmp -Force } catch { Fail "unpack failed: $($_.Exception.Message)" }
    # The archive may or may not have a top-level folder: find the one holding bin\code-server.cmd.
    $found = Get-ChildItem -LiteralPath $tmp -Recurse -Filter 'code-server.cmd' | Select-Object -First 1
    if (-not $found) { Fail 'the downloaded server has no bin\code-server.cmd' }
    Remove-Item $sdir -Recurse -Force -ErrorAction SilentlyContinue
    Move-Item -LiteralPath $found.Directory.Parent.FullName -Destination $sdir
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $zip -Force -ErrorAction SilentlyContinue
}

Say 'CODECHOTE_STATUS Starting server'
$product = Get-Content -Raw -LiteralPath (Join-Path $sdir 'product.json') | ConvertFrom-Json
$commit = if ($product.commit) { $product.commit } else { 'none' }
$quality = if ($product.quality) { $product.quality } else { 'none' }
Copy-Item -LiteralPath (Join-Path $sdir 'product.json') -Destination $productFile -Force

$bytes = New-Object byte[] 24
(New-Object Security.Cryptography.RNGCryptoServiceProvider).GetBytes($bytes)
$token = ($bytes | ForEach-Object { $_.ToString('x2') }) -join ''
$log = Join-Path $D 'server.log'
Remove-Item $log -Force -ErrorAction SilentlyContinue

if ($DryRun -eq 'true') { Say "DRYRUN $arch $sdir $commit $quality $($token.Length)"; return }

# Start it through WMI so it is not a child of this SSH session: Windows ends a session's children when it closes.
$command = "cmd.exe /s /c `"`"$launcher`" --host 127.0.0.1 --port 0 --connection-token $token --accept-server-license-terms --telemetry-level off > `"$log`" 2>&1`""
$started = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $command; CurrentDirectory = $sdir }
if ($started.ReturnValue -ne 0) { Fail "could not start the server (code $($started.ReturnValue))" }
$serverPid = $started.ProcessId

$port = $null
for ($i = 0; $i -lt 150 -and -not $port; $i++) {
    Start-Sleep -Milliseconds 200
    if (Test-Path $log) {
        $fs = [IO.File]::Open($log, 'Open', 'Read', 'ReadWrite')
        try { $text = (New-Object IO.StreamReader($fs)).ReadToEnd() } finally { $fs.Dispose() }
        if ($text -match 'Web UI available at http://[^:\s]+:(\d+)') { $port = $Matches[1] }
    }
    if (-not (Get-Process -Id $serverPid -ErrorAction SilentlyContinue)) { break }
}
if (-not $port) {
    $tail = if (Test-Path $log) { (Get-Content $log -Tail 5) -join ' ' } else { '' }
    Fail "server failed to start: $tail"
}

"PID=$serverPid`r`nPORT=$port`r`nTOKEN=$token`r`nCOMMIT=$commit`r`nQUALITY=$quality" | Set-Content -Encoding ASCII $envFile
Say (Product-Line)
Say "CODECHOTE_READY $port $token $commit $quality"
