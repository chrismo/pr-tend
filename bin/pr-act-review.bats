#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

# Test suite for `pr-act review` (A8): verify first, then the local reviewer
# (settings.localReview, default bin/pr-review-local) over the branch's own
# change. Clean → pin local at HEAD with its base. Findings → printed as JSON,
# nothing pinned. Reviewer failure → nonzero, never clean.
#
# Real git and the real pr-state (gh is a stub that fails, so only git facts).
# The reviewer is a stub that records its env and prints $FX/findings.json.

PR_ACT="$BATS_TEST_DIRNAME/pr-act"
PR_CONFIG="$BATS_TEST_DIRNAME/pr-config"

setup() {
  TMP="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  export GIT_CONFIG_GLOBAL="$TMP/gitconfig-global"
  export GIT_CONFIG_SYSTEM=/dev/null
  printf '[user]\n\temail = t@example.com\n\tname = Tester\n[init]\n\tdefaultBranch = main\n' > "$GIT_CONFIG_GLOBAL"
  export FX="$TMP/fx"
  export PR_TEND_CONFIG="$TMP/global.json"
  mkdir -p "$FX" "$TMP/fakebin"
  printf '#!/usr/bin/env bash\necho "gh called: $*" >&2\nexit 1\n' > "$TMP/fakebin/gh"
  cat > "$TMP/reviewer" <<'EOF'
#!/usr/bin/env bash
{ echo "base=$PR_TEND_BASE"; echo "head=$PR_TEND_HEAD"; echo "task=$PR_TEND_TASK"; echo "cwd=$PWD"; } > "$FX/reviewer.env"
[[ -e $FX/reviewer.fail ]] && { echo "reviewer: boom" >&2; exit 1; }
cat "$FX/findings.json"
EOF
  chmod +x "$TMP/fakebin/gh" "$TMP/reviewer"
  export PATH="$BATS_TEST_DIRNAME:$TMP/fakebin:$PATH"
  echo '[]' > "$FX/findings.json"
  "$PR_CONFIG" set --global settings.localReview "$TMP/reviewer"

  git init -q --bare "$TMP/origin.git"
  git clone -q "$TMP/origin.git" "$TMP/repo" 2>/dev/null
  cd "$TMP/repo"
  printf 'a\nb\n' > file.txt && git add file.txt && git commit -qm init && git push -q origin main 2>/dev/null
  git switch -qc feat
  printf 'a\nb\nc\n' > file.txt && git commit -qam feat
}

env_field() { sed -n "s/^$1=//p" "$FX/reviewer.env"; }
pin() { git rev-parse -q --verify "refs/pr-tend/feat/$1" || true; }

@test "clean: pins local at HEAD with the branch's base" {
  run "$PR_ACT" review
  [ "$status" -eq 0 ]
  [[ "$output" == *"clean"* ]]
  [ "$(pin local)" = "$(git rev-parse HEAD)" ]
  [ "$(pin local-base)" = "$(git rev-parse origin/main)" ]
}

@test "the reviewer gets base, head, task and the worktree as cwd" {
  git config branch.feat.pr-task "add c"
  "$PR_ACT" review >/dev/null
  [ "$(env_field base)" = "$(git rev-parse origin/main)" ]
  [ "$(env_field head)" = "$(git rev-parse HEAD)" ]
  [ "$(env_field task)" = "add c" ]
  [ "$(env_field cwd)" = "$TMP/repo" ]
}

@test "findings: printed as JSON, nothing pinned, exit 0" {
  echo '[{"file": "file.txt", "line": 3, "severity": "warning", "body": "c?"}]' > "$FX/findings.json"
  run --separate-stderr "$PR_ACT" review
  [ "$status" -eq 0 ]
  [ "$(jq -c . <<<"$output")" = '[{"file":"file.txt","line":3,"severity":"warning","body":"c?"}]' ]
  [[ "$stderr" == *"1 finding"* ]]
  [ -z "$(pin local)" ]
}

@test "verify failing: the reviewer never runs" {
  "$PR_CONFIG" set --global settings.verify false
  run "$PR_ACT" review
  [ "$status" -ne 0 ]
  [[ "$output" == *"verify failed"* ]]
  [ ! -e "$FX/reviewer.env" ]
  [ -z "$(pin local)" ]
}

@test "the reviewer failing: nonzero, nothing pinned, never clean" {
  touch "$FX/reviewer.fail"
  run "$PR_ACT" review
  [ "$status" -ne 0 ]
  [[ "$output" == *"reviewer failed"* ]]
  [[ "$output" != *clean* ]]
  [ -z "$(pin local)" ]
}

@test "reviewer output that isn't a JSON list is a failure" {
  echo 'looks fine to me' > "$FX/findings.json"
  run "$PR_ACT" review
  [ "$status" -ne 0 ]
  [ -z "$(pin local)" ]
}

@test "uncommitted changes are refused" {
  echo d >> file.txt
  run "$PR_ACT" review
  [ "$status" -ne 0 ]
  [[ "$output" == *"uncommitted"* ]]
}

@test "a branch checked out nowhere is refused" {
  git branch parked
  run "$PR_ACT" review parked
  [ "$status" -ne 0 ]
}

@test "the default reviewer is bin/pr-review-local and announces the review" {
  "$PR_CONFIG" unset --global settings.localReview
  cat > "$TMP/fakebin/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$FX/claude.args"
echo '{"type": "result", "is_error": false, "structured_output": {"findings": []}}'
EOF
  chmod +x "$TMP/fakebin/claude"
  run --separate-stderr "$PR_ACT" review
  [ "$status" -eq 0 ]
  [ -e "$FX/claude.args" ]
  [[ "$stderr" == *"reviewing feat at"* ]]
  [ "$(pin local)" = "$(git rev-parse HEAD)" ]
}

@test "successful Claude stderr does not leak its JSON protocol output" {
  "$PR_CONFIG" unset --global settings.localReview
  cat > "$TMP/fakebin/claude" <<'EOF'
#!/usr/bin/env bash
echo '{"type":"result","private":"protocol noise"}' >&2
echo '{"type": "result", "is_error": false, "structured_output": {"findings": []}}'
EOF
  chmod +x "$TMP/fakebin/claude"
  run --separate-stderr "$PR_ACT" review
  [ "$status" -eq 0 ]
  [[ "$stderr" != *"protocol noise"* ]]
}
