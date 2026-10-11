# Runs an agent CLI with the prompt on stdin, streaming its output. Variables: $Cwd, $Exe, $ArgList (array), $PromptB64.
Set-Location -LiteralPath $Cwd
$prompt = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($PromptB64))
$prompt | & $Exe @ArgList 2>&1 | ForEach-Object { "$_" }
