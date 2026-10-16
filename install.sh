#!/usr/bin/env bash5
# Link sd into ~/.local/bin ($LOCAL_BIN). Safe to re-run.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
LOCAL_BIN="${LOCAL_BIN:-$HOME/.local/bin}"
mkdir -p "$LOCAL_BIN"

dest="$LOCAL_BIN/sd"
if [[ -e $dest && ! -L $dest ]]; then
  echo "! Skipped sd: $dest exists and is not a symlink"
else
  ln -sfn "$REPO_DIR/bin/sd" "$dest"
  echo "✓ Linked sd -> $LOCAL_BIN/"
fi

for cmd in pr-state pr-act pr-watch pr-config pr-review-local; do
  if [[ -L $LOCAL_BIN/$cmd ]]; then
    rm "$LOCAL_BIN/$cmd"
    echo "✓ Removed $cmd (now sd ${cmd#pr-})"
  fi
done
