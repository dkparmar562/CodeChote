# The user's home folder, with forward slashes.
$h = $env:USERPROFILE
if ([string]::IsNullOrWhiteSpace($h)) { $h = $HOME }
($h -replace '\\', '/')
