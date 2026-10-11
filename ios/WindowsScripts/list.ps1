# List a folder. Variables set by the app: $Path ('' = home folder, '@drives' = the drive list).
# Output: the resolved path (forward slashes) on the first line, then one name per line, folders ending in '/'.
if ($Path -eq '@drives') {
    ''
    Get-PSDrive -PSProvider FileSystem | ForEach-Object { $_.Name + ':/' }
    return
}
if ([string]::IsNullOrWhiteSpace($Path)) { $Path = $env:USERPROFILE }
if ([string]::IsNullOrWhiteSpace($Path)) { $Path = $HOME }
$resolved = (Resolve-Path -LiteralPath $Path).ProviderPath
($resolved -replace '\\', '/')
Get-ChildItem -LiteralPath $resolved -Force -ErrorAction SilentlyContinue | ForEach-Object {
    if ($_.PSIsContainer) { $_.Name + '/' } else { $_.Name }
}
