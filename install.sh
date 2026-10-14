#!/usr/bin/env bash5
# Link the pr-tend commands into ~/.local/bin ($LOCAL_BIN). Safe to re-run.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
LOCAL_BIN="${LOCAL_BIN:-$HOME/.local/bin}"
mkdir -p "$LOCAL_BIN"

for cmd in pr-state pr-act pr-watch pr-config; do
  src="$REPO_DIR/bin/$cmd"
  dest="$LOCAL_BIN/$cmd"
  if [[ -e $dest && ! -L $dest ]]; then
    echo "! Skipped $cmd: $dest exists and is not a symlink"
    continue
  fi
  ln -sfn "$src" "$dest"
  echo "✓ Linked $cmd -> $LOCAL_BIN/"
done
