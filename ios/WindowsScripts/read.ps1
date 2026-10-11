# Read up to $Limit bytes (+1, so the caller can tell the file was cut) of $Path, as one base64 line.
$fs = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
try {
    $length = [int][Math]::Min($fs.Length, [int64]$Limit + 1)
    $buffer = New-Object byte[] $length
    $read = $fs.Read($buffer, 0, $length)
    [Convert]::ToBase64String($buffer, 0, $read)
} finally { $fs.Dispose() }
