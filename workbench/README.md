# The VS Code workbench

A project's VS Code tab runs the real VS Code web UI. The UI ships inside the app (`ios/Resources/vscode-web`)
and is served to the web view locally (`ios/Codechote/Workbench`). Only the VS Code server runs on the host.

| File | What it is |
|---|---|
| `VSCODE_REF` | The VS Code commit the UI is built from. The app installs the server for exactly this commit. |
| `patches/` | Our changes to VS Code (phone layout, native bridges), as one patch. Kept small so it survives upgrades. |
| `build.sh` | Fetches that commit into `.build/vscode-<ref>`, applies the patches, builds the web UI, copies it into the app. |
| `sync-bundle.sh` | The last step of `build.sh`: copies the built UI into `ios/Resources/vscode-web`. |
| `save-patches.sh` | Saves edits made in `.build/vscode-<ref>` back into `patches/`. |
| `VSCODE-LICENSE.txt` | VS Code's license (MIT), which covers the bundled UI. |

```sh
task workbench:build          # first time: fetches VS Code and installs its dependencies (several minutes)
task workbench:quick          # after editing the patched code in .build/vscode-<ref>
task workbench:save-patches   # keep those edits
```

## Why the commit is pinned

The UI and the server talk over a protocol whose shape changes between versions; a mismatch breaks extensions,
not just the UI. So the app ships one UI build and installs the same commit's server on the host
(`~/.codechote-server/server-<commit>`).

## Moving to a newer VS Code

1. Put the new commit in `VSCODE_REF`. Use a release branch commit, so a matching server download exists.
2. `task workbench:build`. If the patch doesn't apply, fix it in `.build/vscode-<ref>`, then run
   `task workbench:save-patches`.
3. Rebuild the app. Each host gets the new server automatically.
