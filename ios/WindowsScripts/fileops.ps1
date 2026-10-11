# One file operation. $Op: createfile | createfolder | rename | delete | replace. $Path, and $Dest for rename and replace.
switch ($Op) {
    'createfile' {
        if (Test-Path -LiteralPath $Path) { throw 'Already exists' }
        New-Item -ItemType File -Path $Path | Out-Null
    }
    'createfolder' { New-Item -ItemType Directory -Force -Path $Path | Out-Null }
    'rename' {
        if (Test-Path -LiteralPath $Dest) { throw 'Something with that name already exists' }
        Move-Item -LiteralPath $Path -Destination $Dest
    }
    'delete' { Remove-Item -LiteralPath $Path -Recurse -Force }
    'replace' { Move-Item -LiteralPath $Path -Destination $Dest -Force }   # move a finished temp file over the original
    default { throw "Unknown operation $Op" }
}
