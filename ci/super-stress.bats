#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

# Test suite for ci/super-stress: every converted SuperDB filter, run many
# times on fixture input; a panic or an output that differs between runs is
# a failure. Needs super 0.3.0 at the pinned asdf path, like pr-config.

STRESS="$BATS_TEST_DIRNAME/super-stress"

setup() {
  TMP="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  printf '{"a": 1, "b": [1, 2]}\n' > "$TMP/in.json"
}

@test "runs under bash 5 via the bash5 shebang" {
  run head -1 "$STRESS"
  [ "$output" = "#!/usr/bin/env bash5" ]
}

@test "the built-in filters all run clean and the summary counts them" {
  run "$STRESS" -n 2
  [ "$status" -eq 0 ]
  [[ "${lines[-1]}" =~ ^super-stress:\ ([0-9]+)\ filters,\ 2\ runs\ each,\ 0\ failures$ ]] || false
  (( BASH_REMATCH[1] >= 10 ))
}

@test "a named filter: the query file over the fixture, the given number of times" {
  echo 'values {n: len(b), a}' > "$TMP/q.spq"
  run "$STRESS" -n 5 "good=$TMP/q.spq:$TMP/in.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"good: 5 runs, 0 failures"* ]] || false
  [ "${lines[-1]}" = "super-stress: 1 filters, 5 runs each, 0 failures" ]
}

@test "output that differs between runs is a failure, and the summary says which filter" {
  echo 'values now()' > "$TMP/q.spq"
  run "$STRESS" -n 3 "clock=$TMP/q.spq:$TMP/in.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"clock: 3 runs, 2 failures"* ]] || false
  [[ "$output" == *"differs"* ]] || false
  [ "${lines[-1]}" = "super-stress: 1 filters, 3 runs each, 2 failures" ]
}

@test "a run that doesn't exit 0 is a failure" {
  echo 'values nosuchfunction(a)' > "$TMP/q.spq"
  run "$STRESS" -n 2 "broken=$TMP/q.spq:$TMP/in.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"broken: 2 runs, 2 failures"* ]] || false
  [[ "$output" == *"exit "* ]] || false
}

@test "line mode prints raw strings; the mode is the fourth field" {
  echo 'values f"a={a}"' > "$TMP/q.spq"
  run "$STRESS" -n 1 "raw=$TMP/q.spq:$TMP/in.json:line"
  [ "$status" -eq 0 ]
  [[ "$output" == *"raw: 1 runs, 0 failures"* ]] || false
}
