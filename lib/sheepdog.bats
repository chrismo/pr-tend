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
  export SHEEPDOG_CONFIG="$TMP/global.json" SHEEPDOG_STATE_DIR="$TMP/state"
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
echo "${ANTHROPIC_API_KEY-unset}" > "$FX/key"
printf '%s\n' "$@" > "$FX/args"
cat "$FX/out"
exit "$(cat "$FX/status" 2>/dev/null || echo 0)"
EOF
    chmod +x "$TMP/fakebin/$h"
  done
  export PATH="$TMP/fakebin:$PATH"
  echo '{"type": "result", "is_error": false, "structured_output": {"ok": true}}' > "$FX/out"
}

@test "harness_run: claude runs without ANTHROPIC_API_KEY, so the claude.ai login is used" {
  harness_stubs
  export ANTHROPIC_API_KEY=sk-no-credit
  run harness_run claude sid1 new 30 "do it" '{}'
  [ "$status" -eq 0 ]
  [ "$(cat "$FX/key")" = unset ]
}

@test "harness_run: harnesses.claude.useApiKey keeps the key" {
  harness_stubs
  export ANTHROPIC_API_KEY=sk-paid
  run harness_run claude sid1 new 30 "do it" '{}' '{"harness": "claude", "useApiKey": true}'
  [ "$status" -eq 0 ]
  [ "$(cat "$FX/key")" = sk-paid ]
  run harness_run claude sid1 new 30 "do it" '{}' '{"harness": "claude", "useApiKey": false}'
  [ "$(cat "$FX/key")" = unset ]
}

@test "harness_run: pi keeps the key; it can't use the claude.ai login" {
  harness_stubs
  export ANTHROPIC_API_KEY=sk-paid
  printf 'Done.\n\n```json\n{"ok": true}\n```\n' > "$FX/out"
  run harness_run pi sid1 new 30 "do it" '{}'
  [ "$status" -eq 0 ]
  [ "$(cat "$FX/key")" = sk-paid ]
}

@test "harness_run: settings.stepBudget caps a claude step's spend; 0 is no cap" {
  harness_stubs
  run harness_run claude sid1 new 30 "do it" '{}'
  [ "$status" -eq 0 ]
  ! grep -q -- --max-budget-usd "$FX/args"
  echo '{"settings": {"stepBudget": 2.5}}' > "$SHEEPDOG_CONFIG"
  run harness_run claude sid1 new 30 "do it" '{}'
  [ "$status" -eq 0 ]
  [ "$(grep -A1 -x -- --max-budget-usd "$FX/args" | tail -1)" = 2.5 ]
}

@test "harness_run: pi has no budget flag" {
  harness_stubs
  echo '{"settings": {"stepBudget": 2.5}}' > "$SHEEPDOG_CONFIG"
  printf 'Done.\n\n```json\n{"ok": true}\n```\n' > "$FX/out"
  run harness_run pi sid1 new 30 "do it" '{}'
  [ "$status" -eq 0 ]
  ! grep -q -- budget "$FX/args"
}

@test "harness_run: a step that hits the budget fails and says so" {
  harness_stubs
  echo '{"settings": {"stepBudget": 0.1}}' > "$SHEEPDOG_CONFIG"
  echo '{"type": "result", "is_error": true, "subtype": "error_max_budget_usd", "result": null, "total_cost_usd": 0.1353}' > "$FX/out"
  run --separate-stderr harness_run claude sid1 new 30 "do it" '{}'
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"settings.stepBudget (0.1 USD)"* ]]
  [[ "$stderr" == *"0.1353"* ]]
}

@test "harness_run: every claude step appends its usage to usage.tsv" {
  harness_stubs
  echo '{"type": "result", "is_error": false, "structured_output": {"ok": true}, "total_cost_usd": 0.25, "duration_ms": 4321, "num_turns": 3,
         "usage": {"input_tokens": 10, "cache_creation_input_tokens": 200, "cache_read_input_tokens": 3000, "output_tokens": 40}}' > "$FX/out"
  HARNESS_STEP=implement run harness_run claude sid1 resume 30 "do it" '{}'
  [ "$status" -eq 0 ]
  [ "$(head -1 "$SHEEPDOG_STATE_DIR/usage.tsv")" = $'time\trepo\tbranch\tstep\tharness\tsession\tmode\tstatus\tcost_usd\tinput\tcache_create\tcache_read\toutput\tduration_ms\tturns' ]
  line=$(sed -n 2p "$SHEEPDOG_STATE_DIR/usage.tsv")
  [[ $line =~ ^20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9:]+Z$'\t'"$TMP/repo"$'\tfeat\timplement\tclaude\tsid1\tresume\t0\t0.25\t10\t200\t3000\t40\t4321\t3'$ ]]
  run harness_run claude sid1 resume 30 "again" '{}'
  [ "$(wc -l < "$SHEEPDOG_STATE_DIR/usage.tsv")" -eq 3 ]
  [[ "$(sed -n 3p "$SHEEPDOG_STATE_DIR/usage.tsv")" == *$'\tclaude\tsid1\tresume\t0\t0.25\t'* ]]
  [[ "$(sed -n 3p "$SHEEPDOG_STATE_DIR/usage.tsv")" == *$'\tfeat\t\tclaude\t'* ]]
}

@test "harness_run: a failed step is logged with its status, and pi's row has no cost" {
  harness_stubs
  echo 1 > "$FX/status"
  run harness_run claude sid1 new 30 "do it" '{}'
  [ "$status" -ne 0 ]
  [[ "$(sed -n 2p "$SHEEPDOG_STATE_DIR/usage.tsv")" == *$'\tclaude\tsid1\tnew\t1\t'* ]]
  rm "$FX/status"
  printf 'Done.\n\n```json\n{"ok": true}\n```\n' > "$FX/out"
  run harness_run pi sid2 new 30 "do it" '{}'
  [ "$status" -eq 0 ]
  [[ "$(sed -n 3p "$SHEEPDOG_STATE_DIR/usage.tsv")" == *$'\tpi\tsid2\tnew\t0\t\t\t\t\t\t\t' ]]
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
  [[ "$stderr" == *"line 11"$'\n'*"line 30"* ]]
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
