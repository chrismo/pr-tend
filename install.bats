#!/usr/bin/env bats

# Test suite for install.sh. LOCAL_BIN points at a temp dir so tests never
# touch the real ~/.local/bin.

INSTALLER="$BATS_TEST_DIRNAME/install.sh"
COMMANDS=(pr-state pr-act pr-watch pr-config)

setup() {
  TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pr-tend-install.XXXXXX")"
  export LOCAL_BIN="$TEST_DIR/local-bin"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "links every command into LOCAL_BIN" {
  run "$INSTALLER"
  [ "$status" -eq 0 ]
  local cmd
  for cmd in "${COMMANDS[@]}"; do
    [ -L "$LOCAL_BIN/$cmd" ]
    [ "$(readlink "$LOCAL_BIN/$cmd")" = "$BATS_TEST_DIRNAME/bin/$cmd" ]
  done
}

@test "replaces a link left by another checkout" {
  mkdir -p "$LOCAL_BIN"
  ln -s /somewhere/agent-rig/bin/pr-act "$LOCAL_BIN/pr-act"
  run "$INSTALLER"
  [ "$status" -eq 0 ]
  [ "$(readlink "$LOCAL_BIN/pr-act")" = "$BATS_TEST_DIRNAME/bin/pr-act" ]
}

@test "leaves a regular file alone and says so" {
  mkdir -p "$LOCAL_BIN"
  echo mine > "$LOCAL_BIN/pr-state"
  run "$INSTALLER"
  [ "$status" -eq 0 ]
  [ ! -L "$LOCAL_BIN/pr-state" ]
  [ "$(cat "$LOCAL_BIN/pr-state")" = mine ]
  [[ "$output" == *"pr-state"*"not a symlink"* ]]
  [ -L "$LOCAL_BIN/pr-act" ]
}
