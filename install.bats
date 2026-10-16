#!/usr/bin/env bats

# Test suite for install.sh. LOCAL_BIN points at a temp dir so tests never
# touch the real ~/.local/bin.

INSTALLER="$BATS_TEST_DIRNAME/install.sh"
OLD_COMMANDS=(pr-state pr-act pr-watch pr-config pr-review-local)

setup() {
  TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sheepdog-install.XXXXXX")"
  export LOCAL_BIN="$TEST_DIR/local-bin"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "links sd into LOCAL_BIN" {
  run "$INSTALLER"
  [ "$status" -eq 0 ]
  [ -L "$LOCAL_BIN/sd" ]
  [ "$(readlink "$LOCAL_BIN/sd")" = "$BATS_TEST_DIRNAME/bin/sd" ]
}

@test "links nothing else: the verbs are reached through sd" {
  run "$INSTALLER"
  [ "$status" -eq 0 ]
  [ "$(ls "$LOCAL_BIN")" = sd ]
}

@test "replaces a link left by another checkout" {
  mkdir -p "$LOCAL_BIN"
  ln -s /somewhere/else/bin/sd "$LOCAL_BIN/sd"
  run "$INSTALLER"
  [ "$status" -eq 0 ]
  [ "$(readlink "$LOCAL_BIN/sd")" = "$BATS_TEST_DIRNAME/bin/sd" ]
}

@test "leaves a regular file alone and says so" {
  mkdir -p "$LOCAL_BIN"
  echo mine > "$LOCAL_BIN/sd"
  run "$INSTALLER"
  [ "$status" -eq 0 ]
  [ ! -L "$LOCAL_BIN/sd" ]
  [ "$(cat "$LOCAL_BIN/sd")" = mine ]
  [[ "$output" == *"sd"*"not a symlink"* ]]
}

@test "removes pr-* links from a pr-tend install" {
  mkdir -p "$LOCAL_BIN"
  local cmd
  for cmd in "${OLD_COMMANDS[@]}"; do
    ln -s "/somewhere/pr-tend/bin/$cmd" "$LOCAL_BIN/$cmd"
  done
  run "$INSTALLER"
  [ "$status" -eq 0 ]
  for cmd in "${OLD_COMMANDS[@]}"; do
    [ ! -L "$LOCAL_BIN/$cmd" ]
  done
  [[ "$output" == *"Removed pr-act"* ]]
}

@test "leaves a regular file with an old command's name alone" {
  mkdir -p "$LOCAL_BIN"
  echo mine > "$LOCAL_BIN/pr-state"
  run "$INSTALLER"
  [ "$status" -eq 0 ]
  [ "$(cat "$LOCAL_BIN/pr-state")" = mine ]
}
