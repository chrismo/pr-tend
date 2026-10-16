#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

# Test suite for `sd act review` (A8): verify first, then the local reviewer
# (settings.localReview, default libexec/sd-review-local) over the branch's own
# change. Clean → pin local at HEAD with its base. Findings → printed as JSON,
# nothing pinned. Reviewer failure → nonzero, never clean.
#
# Real git and the real sd state (gh is a stub that fails, so only git facts).
# The reviewer is a stub that records its env and prints $FX/findings.json.

SD_ACT="$BATS_TEST_DIRNAME/sd-act"
SD_CONFIG="$BATS_TEST_DIRNAME/sd-config"

setup() {
  TMP="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  export GIT_CONFIG_GLOBAL="$TMP/gitconfig-global"
  export GIT_CONFIG_SYSTEM=/dev/null
  export SHEEPDOG_STATE_DIR="$TMP/state"   # harness_run logs usage there
  printf '[user]\n\temail = t@example.com\n\tname = Tester\n[init]\n\tdefaultBranch = main\n' > "$GIT_CONFIG_GLOBAL"
  export FX="$TMP/fx"
  export SHEEPDOG_CONFIG="$TMP/global.json"
  mkdir -p "$FX" "$TMP/fakebin"
  printf '#!/usr/bin/env bash\necho "gh called: $*" >&2\nexit 1\n' > "$TMP/fakebin/gh"
  cat > "$TMP/reviewer" <<'EOF'
#!/usr/bin/env bash
{ echo "base=$SHEEPDOG_BASE"; echo "head=$SHEEPDOG_HEAD"; echo "task=$SHEEPDOG_TASK"; echo "cwd=$PWD"; } > "$FX/reviewer.env"
[[ -e $FX/reviewer.fail ]] && { echo "reviewer: boom" >&2; exit 1; }
cat "$FX/findings.json"
EOF
  chmod +x "$TMP/fakebin/gh" "$TMP/reviewer"
  export PATH="$BATS_TEST_DIRNAME:$TMP/fakebin:$PATH"
  echo '[]' > "$FX/findings.json"
  "$SD_CONFIG" set --global settings.localReview "$TMP/reviewer"

  git init -q --bare "$TMP/origin.git"
  git clone -q "$TMP/origin.git" "$TMP/repo" 2>/dev/null
  cd "$TMP/repo"
  printf 'a\nb\n' > file.txt && git add file.txt && git commit -qm init && git push -q origin main 2>/dev/null
  git switch -qc feat
  printf 'a\nb\nc\n' > file.txt && git commit -qam feat
}

env_field() { sed -n "s/^$1=//p" "$FX/reviewer.env"; }
pin() { git rev-parse -q --verify "refs/sheepdog/feat/$1" || true; }

@test "clean: pins local at HEAD with the branch's base" {
  run "$SD_ACT" review
  [ "$status" -eq 0 ]
  [[ "$output" == *"clean"* ]]
  [ "$(pin local)" = "$(git rev-parse HEAD)" ]
  [ "$(pin local-base)" = "$(git rev-parse origin/main)" ]
}

@test "the reviewer gets base, head, task and the worktree as cwd" {
  git config branch.feat.sd-task "add c"
  "$SD_ACT" review >/dev/null
  [ "$(env_field base)" = "$(git rev-parse origin/main)" ]
  [ "$(env_field head)" = "$(git rev-parse HEAD)" ]
  [ "$(env_field task)" = "add c" ]
  [ "$(env_field cwd)" = "$TMP/repo" ]
}

@test "findings: printed as JSON, nothing pinned, exit 0" {
  echo '[{"file": "file.txt", "line": 3, "severity": "warning", "body": "c?"}]' > "$FX/findings.json"
  run --separate-stderr "$SD_ACT" review
  [ "$status" -eq 0 ]
  [ "$(jq -c . <<<"$output")" = '[{"file":"file.txt","line":3,"severity":"warning","body":"c?"}]' ]
  [[ "$stderr" == *"1 finding"* ]]
  [ -z "$(pin local)" ]
}

@test "verify failing: the reviewer never runs" {
  "$SD_CONFIG" set --global settings.verify false
  run "$SD_ACT" review
  [ "$status" -ne 0 ]
  [[ "$output" == *"verify failed"* ]]
  [ ! -e "$FX/reviewer.env" ]
  [ -z "$(pin local)" ]
}

@test "the reviewer failing: nonzero, nothing pinned, never clean" {
  touch "$FX/reviewer.fail"
  run "$SD_ACT" review
  [ "$status" -ne 0 ]
  [[ "$output" == *"reviewer failed"* ]]
  [[ "$output" != *clean* ]]
  [ -z "$(pin local)" ]
}

@test "reviewer output that isn't a JSON list is a failure" {
  echo 'looks fine to me' > "$FX/findings.json"
  run "$SD_ACT" review
  [ "$status" -ne 0 ]
  [ -z "$(pin local)" ]
}

@test "uncommitted changes are refused" {
  echo d >> file.txt
  run "$SD_ACT" review
  [ "$status" -ne 0 ]
  [[ "$output" == *"uncommitted"* ]]
}

@test "a branch checked out nowhere is refused" {
  git branch parked
  run "$SD_ACT" review parked
  [ "$status" -ne 0 ]
}

@test "the default reviewer is libexec/sd-review-local" {
  "$SD_CONFIG" unset --global settings.localReview
  cat > "$TMP/fakebin/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$FX/claude.args"
echo '{"type": "result", "is_error": false, "structured_output": {"findings": []}}'
EOF
  chmod +x "$TMP/fakebin/claude"
  run "$SD_ACT" review
  [ "$status" -eq 0 ]
  [ -e "$FX/claude.args" ]
  [ "$(pin local)" = "$(git rev-parse HEAD)" ]
}

@test "a hung default reviewer times out inside, so the harness's stderr still shows" {
  "$SD_CONFIG" unset --global settings.localReview
  "$SD_CONFIG" set --global settings.stepTimeout 1
  cat > "$TMP/fakebin/claude" <<'EOF2'
#!/usr/bin/env bash
echo "claude: still thinking" >&2
sleep 5
EOF2
  chmod +x "$TMP/fakebin/claude"
  run --separate-stderr "$SD_ACT" review
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"claude: still thinking"* ]]
  [[ "$stderr" == *"timed out after 1s"* ]]
  [ -z "$(pin local)" ]
}

@test "a custom reviewer gets stepTimeout, with no margin" {
  "$SD_CONFIG" set --global settings.stepTimeout 1
  printf '#!/usr/bin/env bash\nsleep 3\necho "[]"\n' > "$TMP/reviewer"
  run --separate-stderr "$SD_ACT" review
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"timed out after 1s"* ]]
  [ -z "$(pin local)" ]
}
