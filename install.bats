#!/usr/bin/env bats

# The fixture sd records watcher installation without touching launchd.
OLD_COMMANDS=(pr-state pr-act pr-watch pr-config pr-review-local)

setup() {
  TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sheepdog-install.XXXXXX")"
  TEST_DIR="$(cd "$TEST_DIR" && pwd -P)"
  export LOCAL_BIN="$TEST_DIR/local-bin"
  export WATCH_CALLS="$TEST_DIR/watch-calls"
  INSTALLER="$TEST_DIR/repo/install.sh"
  mkdir -p "$TEST_DIR/repo/bin" "$TEST_DIR/fakebin"
  cat > "$TEST_DIR/fakebin/uname" <<'EOF'
#!/usr/bin/env bash5
printf '%s\n' "${TEST_OS:-Darwin}"
EOF
  chmod +x "$TEST_DIR/fakebin/uname"
  export PATH="$TEST_DIR/fakebin:$PATH"
  cp "$BATS_TEST_DIRNAME/install.sh" "$INSTALLER"
  cat > "$TEST_DIR/repo/bin/sd" <<'EOF'
#!/usr/bin/env bash5
[[ -L $LOCAL_BIN/sd ]] || exit 99
printf '%s\n' "$*" >> "$WATCH_CALLS"
exit "${WATCH_EXIT:-0}"
EOF
  chmod +x "$TEST_DIR/repo/bin/sd"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "links sd into LOCAL_BIN" {
  run "$INSTALLER"
  [ "$status" -eq 0 ]
  [ -L "$LOCAL_BIN/sd" ]
  [ "$(readlink "$LOCAL_BIN/sd")" = "$TEST_DIR/repo/bin/sd" ]
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
  [ "$(readlink "$LOCAL_BIN/sd")" = "$TEST_DIR/repo/bin/sd" ]
}

@test "a regular file blocks installation without being overwritten or installing the watcher" {
  mkdir -p "$LOCAL_BIN"
  echo mine > "$LOCAL_BIN/sd"
  ln -s /somewhere/pr-watch "$LOCAL_BIN/pr-watch"
  run "$INSTALLER"
  [ "$status" -ne 0 ]
  [ ! -e "$WATCH_CALLS" ]
  [ ! -L "$LOCAL_BIN/sd" ]
  [ "$(cat "$LOCAL_BIN/sd")" = mine ]
  [ "$(readlink "$LOCAL_BIN/pr-watch")" = /somewhere/pr-watch ]
  [[ "$output" == *"sd"*"not a symlink"* ]]
}

@test "installs the watcher by default after linking sd" {
  run "$INSTALLER"
  [ "$status" -eq 0 ]
  [ "$(cat "$WATCH_CALLS")" = "watch install" ]
}

@test "reinstalling sd reinstalls the watcher" {
  "$INSTALLER"
  run "$INSTALLER"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$WATCH_CALLS" | tr -d ' ')" -eq 2 ]
}

@test "a watcher installation failure fails the installer" {
  export WATCH_EXIT=42
  run "$INSTALLER"
  [ "$status" -eq 42 ]
  [ "$(cat "$WATCH_CALLS")" = "watch install" ]
  [[ "$output" == *"linked"*"watcher installation failed"*"sd watch install"* ]]
}

@test "on Linux links sd and explains that the background watcher requires macOS" {
  export TEST_OS=Linux
  run "$INSTALLER"
  [ "$status" -eq 0 ]
  [ -L "$LOCAL_BIN/sd" ]
  [ ! -e "$WATCH_CALLS" ]
  [[ "$output" == *"watcher requires macOS"* ]]
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
