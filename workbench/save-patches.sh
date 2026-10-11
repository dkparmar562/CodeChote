#!/usr/bin/env bash
# Saves the changes made in the VS Code checkout (.build/vscode-<ref>) back into workbench/patches/.
#   workbench/save-patches.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REF="$(cat "$ROOT/workbench/VSCODE_REF")"
WT="$ROOT/.build/vscode-${REF:0:7}"
git -C "$WT" add -A src
git -C "$WT" diff --cached "$REF" -- src > "$ROOT/workbench/patches/0001-phone-layout-and-native-bridges.patch"
git -C "$WT" diff --cached "$REF" --stat -- src | tail -1
