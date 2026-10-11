#!/usr/bin/env bash
# Builds the VS Code workbench UI that ships inside the app (the "VS Code" screens of a project).
#
#   workbench/build.sh [vscode-ref]
#
# 1. checks out the pinned VS Code commit (workbench/VSCODE_REF) in .build/vscode-<ref>, fetching just that
#    commit from GitHub the first time,
# 2. applies our patches (workbench/patches/*.patch) on top of it,
# 3. builds the web UI from that checkout, and
# 4. copies the result, plus the commit it came from, into the app (ios/Resources/vscode-web).
#
# The UI and the VS Code server on the host must be the *same commit*: the app reads the commit from the
# bundle and installs exactly that server. To move to a newer VS Code: put the new ref in workbench/VSCODE_REF
# (or pass it here). If a patch no longer applies cleanly, fix it in the checkout and run save-patches.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HERE="$ROOT/workbench"
REF="${1:-$(cat "$HERE/VSCODE_REF")}"
SHORT="${REF:0:7}"
WT="$ROOT/.build/vscode-$SHORT"

if [ ! -d "$WT" ]; then
  echo "==> fetching VS Code $SHORT"
  mkdir -p "$WT"
  git -C "$WT" init -q
  git -C "$WT" fetch --no-tags --depth=1 https://github.com/microsoft/vscode.git "$REF"
  git -C "$WT" checkout -q --detach FETCH_HEAD
  echo "==> applying patches"
  for patch in "$HERE"/patches/*.patch; do
    git -C "$WT" apply --3way "$patch"
  done
fi

# VS Code builds with the Node version in its .nvmrc.
if [ -s "$HOME/.nvm/nvm.sh" ]; then . "$HOME/.nvm/nvm.sh" >/dev/null; nvm use "$(cat "$WT/.nvmrc")" >/dev/null 2>&1 || nvm install "$(cat "$WT/.nvmrc")"; fi

cd "$WT"
[ -d node_modules ] || { echo "==> installing dependencies (once, a few minutes)"; npm ci; }

# The web package (node_modules, built-in extensions, icon font) only changes with the VS Code version, so
# later builds can skip it:  QUICK=1 workbench/build.sh
if [ -z "${QUICK:-}" ] || [ ! -d "$ROOT/.build/vscode-web/node_modules" ]; then
  echo "==> building the web package (also generates the icon font the bundle needs)"
  npm run gulp vscode-web-min
fi
echo "==> building the workbench bundle"
node build/next/index.ts bundle --out out-vscode-reh-web-min --target server-web --nls

"$HERE/sync-bundle.sh" "$WT" "$ROOT/.build/vscode-web"
echo "==> done. Rebuild the app (ios/scripts/sim.sh or ios/scripts/install.sh)."
