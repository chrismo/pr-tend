#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

# Test suite for lib/sheepdog.sh, the helpers shared by sd state, sd act and
# sd watch. Needs bash 5 first on PATH (the lib is sourced).

setup() {
  source "$BATS_TEST_DIRNAME/config.sh"
  source "$BATS_TEST_DIRNAME/sheepdog.sh"
  TMP="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  export GIT_CONFIG_GLOBAL="$TMP/gitconfig-global"
  export GIT_CONFIG_SYSTEM=/dev/null
  printf '[user]\n\temail = t@example.com\n\tname = Tester\n[init]\n\tdefaultBranch = main\n' > "$GIT_CONFIG_GLOBAL"
  git init -q "$TMP/repo" && cd "$TMP/repo"
  git commit -q --allow-empty -m init
  git switch -qc feat && git commit -q --allow-empty -m one
}

@test "pin_write records the pin and the base it was taken against" {
  pin_write feat local HEAD main
  [ "$(git rev-parse refs/sheepdog/feat/local)" = "$(git rev-parse HEAD)" ]
  [ "$(git rev-parse refs/sheepdog/feat/local-base)" = "$(git rev-parse main)" ]
}

@test "pin_write overwrites both refs, so a stale base never outlives its pin" {
  pin_write feat bot HEAD main
  git commit -q --allow-empty -m two
  pin_write feat bot HEAD HEAD~1
  [ "$(git rev-parse refs/sheepdog/feat/bot)" = "$(git rev-parse HEAD)" ]
  [ "$(git rev-parse refs/sheepdog/feat/bot-base)" = "$(git rev-parse HEAD~1)" ]
}

@test "pin_write refuses a pin kind it doesn't know" {
  run pin_write feat nope HEAD main
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown pin"* ]]
}

# harness_run's tests: claude and pi are stubs that put protocol noise on
# stderr and print $FX/out on stdout, exiting $FX/status.
harness_stubs() {
  export FX="$TMP/fx"
  mkdir -p "$FX" "$TMP/fakebin"
  for h in claude pi; do
    cat > "$TMP/fakebin/$h" <<'EOF'
#!/usr/bin/env bash
echo '{"type":"system","subtype":"init","session_id":"x"}' >&2
cat "$FX/out"
exit "$(cat "$FX/status" 2>/dev/null || echo 0)"
EOF
    chmod +x "$TMP/fakebin/$h"
  done
  export PATH="$TMP/fakebin:$PATH"
  echo '{"type": "result", "is_error": false, "structured_output": {"ok": true}}' > "$FX/out"
}

@test "harness_run: a successful run keeps the harness's stderr off the terminal" {
  harness_stubs
  run --separate-stderr harness_run claude sid1 new 30 "do it" '{}'
  [ "$status" -eq 0 ]
  [ "$(jq -c . <<<"$output")" = '{"ok":true}' ]
  [ -z "$stderr" ]
}

@test "harness_run: a failed run shows the harness's stderr" {
  harness_stubs
  echo 1 > "$FX/status"
  run --separate-stderr harness_run claude sid1 new 30 "do it" '{}'
  [ "$status" -ne 0 ]
  [[ "$stderr" == *'"subtype":"init"'* ]]
}

@test "harness_run: an error result is a failure, so the stderr shows" {
  harness_stubs
  echo '{"type": "result", "is_error": true, "result": "out of turns"}' > "$FX/out"
  run --separate-stderr harness_run claude sid1 new 30 "do it" '{}'
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [[ "$stderr" == *'"subtype":"init"'* ]]
  [[ "$stderr" == *"out of turns"* ]]
}

@test "harness_run: an error result without result text names its subtype" {
  harness_stubs
  echo '{"type": "result", "subtype": "error_max_turns", "is_error": true}' > "$FX/out"
  run --separate-stderr harness_run claude sid1 new 30 "do it" '{}'
  [ "$status" -ne 0 ]
  [[ "$stderr" == *error_max_turns* ]]
}

@test "harness_run: a success result with nothing usable doesn't print its subtype" {
  harness_stubs
  echo '{"type": "result", "subtype": "success", "is_error": false, "result": ""}' > "$FX/out"
  run --separate-stderr harness_run claude sid1 new 30 "do it" '{}'
  [ "$status" -ne 0 ]
  [[ "$stderr" != *success* ]]
}

@test "harness_run: pi replying without a json block shows the end of the reply" {
  harness_stubs
  printf 'I need to know which file you mean.\n' > "$FX/out"
  run --separate-stderr harness_run pi sid1 new 30 "do it" '{}'
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"which file you mean"* ]]
}

@test "harness_run: claude failing with stdout that isn't JSON shows its end" {
  harness_stubs
  printf 'Error: unknown option --bogus\n' > "$FX/out"
  echo 1 > "$FX/status"
  run --separate-stderr harness_run claude sid1 new 30 "do it" '{}'
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"unknown option --bogus"* ]]
}

@test "harness_run: claude's error text is cut to its last 20 lines" {
  harness_stubs
  jq -n '{type: "result", is_error: true, result: ([range(1; 31) | "line \(.)"] | join("\n"))}' > "$FX/out"
  run --separate-stderr harness_run claude sid1 new 30 "do it" '{}'
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"line 30"* ]]
  [[ "$stderr" != *"line 10"$'\n'* ]]
}

@test "harness_run: pi's stderr follows the same rule" {
  harness_stubs
  printf 'Done.\n\n```json\n{"ok": true}\n```\n' > "$FX/out"
  run --separate-stderr harness_run pi sid1 new 30 "do it" '{}'
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  echo 1 > "$FX/status"
  run --separate-stderr harness_run pi sid1 new 30 "do it" '{}'
  [ "$status" -ne 0 ]
  [[ "$stderr" == *'"subtype":"init"'* ]]
}
