#!/usr/bin/env bash
# Assembles the UI that ships inside the app (ios/Resources/vscode-web) from two builds of the VS Code checkout:
#   out/                       <- <checkout>/out-vscode-reh-web-min   (has workbench.js/css)
#   node_modules/, extensions/ <- .build/vscode-web                   (gulp vscode-web-min)
# Usage: workbench/sync-bundle.sh [vscode-checkout] [vscode-web-dir]   (normally called by workbench/build.sh)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="${1:-$ROOT/.build/vscode-$(cut -c1-7 "$ROOT/workbench/VSCODE_REF")}"
WEB="${2:-$ROOT/.build/vscode-web}"
DEST="$ROOT/ios/Resources/vscode-web"

[ -f "$REPO/out-vscode-reh-web-min/vs/code/browser/workbench/workbench.js" ] || { echo "missing out-vscode-reh-web-min in $REPO (run: npm run gulp esbuild-vscode-reh-web-min)" >&2; exit 1; }
[ -d "$WEB/node_modules" ] || { echo "missing vscode-web build: $WEB (run: npm run gulp vscode-web-min)" >&2; exit 1; }

rm -rf "$DEST"; mkdir -p "$DEST/resources/server"
rsync -a --exclude '*.map' --exclude '*.d.ts' "$REPO/out-vscode-reh-web-min/" "$DEST/out/"
rsync -a --exclude '*.map' --exclude '*.d.ts' "$WEB/node_modules/" "$DEST/node_modules/"
rsync -a --exclude '*.map' "$WEB/extensions/" "$DEST/extensions/"
git -C "$REPO" rev-parse HEAD > "$DEST/ui-commit.txt"   # the server installed on the host must be this exact commit
cp "$WEB"/code-192.png "$WEB"/code-512.png "$WEB"/favicon.ico "$WEB"/manifest.json "$DEST/resources/server/"
du -sh "$DEST"
