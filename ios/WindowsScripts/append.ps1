# Write one chunk of a file. $Data is base64; $Truncate = 'true' starts the file over.
$bytes = [Convert]::FromBase64String($Data)
$mode = if ($Truncate -eq 'true') { 'Create' } else { 'Append' }
$fs = [IO.File]::Open($Path, $mode, 'Write', 'Read')
try { $fs.Write($bytes, 0, $bytes.Length) } finally { $fs.Dispose() }
