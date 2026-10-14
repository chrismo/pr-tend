#!/usr/bin/env bats

# Test suite for lib/pr-tend.sh, the helpers shared by pr-state, pr-act and
# pr-watch. Needs bash 5 first on PATH (the lib is sourced).

setup() {
  source "$BATS_TEST_DIRNAME/pr-tend.sh"
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
  [ "$(git rev-parse refs/pr-tend/feat/local)" = "$(git rev-parse HEAD)" ]
  [ "$(git rev-parse refs/pr-tend/feat/local-base)" = "$(git rev-parse main)" ]
}

@test "pin_write overwrites both refs, so a stale base never outlives its pin" {
  pin_write feat bot HEAD main
  git commit -q --allow-empty -m two
  pin_write feat bot HEAD HEAD~1
  [ "$(git rev-parse refs/pr-tend/feat/bot)" = "$(git rev-parse HEAD)" ]
  [ "$(git rev-parse refs/pr-tend/feat/bot-base)" = "$(git rev-parse HEAD~1)" ]
}

@test "pin_write refuses a pin kind it doesn't know" {
  run pin_write feat nope HEAD main
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown pin"* ]]
}
