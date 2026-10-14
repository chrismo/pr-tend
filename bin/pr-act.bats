#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

# Test suite for bin/pr-act (mechanical pipeline verbs). Only enroll/unenroll
# so far: the config the watcher reads.

PR_ACT="$BATS_TEST_DIRNAME/pr-act"

setup() {
  TMP="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  export GIT_CONFIG_GLOBAL="$TMP/gitconfig-global"
  export GIT_CONFIG_SYSTEM=/dev/null
  printf '[user]\n\temail = t@example.com\n\tname = Tester\n[init]\n\tdefaultBranch = main\n' > "$GIT_CONFIG_GLOBAL"
  git init -q "$TMP/repo"
  cd "$TMP/repo"
  git commit -q --allow-empty -m init
  git switch -qc feat
}

repos() { git config --global --get-all pr-tend.repo || true; }

@test "runs under bash 5 via the bash5 shebang" {
  run head -1 "$PR_ACT"
  [ "$output" = "#!/usr/bin/env bash5" ]
}

@test "no verb: usage on stderr, nonzero" {
  run "$PR_ACT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Usage"* ]]
}

@test "unknown verb fails" {
  run "$PR_ACT" frobnicate
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown verb"* ]]
}

@test "enroll: marks the current branch and registers the repo" {
  run "$PR_ACT" enroll
  [ "$status" -eq 0 ]
  [[ "$output" == *"enrolled feat"* ]]
  [ "$(git config branch.feat.pr-tend)" = true ]
  [ "$(repos)" = "$TMP/repo" ]
}

@test "enroll: a named branch" {
  git branch other
  run "$PR_ACT" enroll other
  [ "$status" -eq 0 ]
  [ "$(git config branch.other.pr-tend)" = true ]
  [ -z "$(git config branch.feat.pr-tend || true)" ]
}

@test "enroll: a missing branch fails" {
  run "$PR_ACT" enroll nope
  [ "$status" -ne 0 ]
  [[ "$output" == *"no such branch"* ]]
}

@test "enroll: registers the repo only once" {
  "$PR_ACT" enroll
  git branch other
  "$PR_ACT" enroll other
  [ "$(repos | wc -l | tr -d ' ')" = 1 ]
}

@test "enroll: from a linked worktree, registers the main worktree" {
  git switch -q main
  git worktree add -q "$TMP/wt" feat
  cd "$TMP/wt"
  run "$PR_ACT" enroll
  [ "$status" -eq 0 ]
  [ "$(repos)" = "$TMP/repo" ]
}

@test "unenroll: clears the mark" {
  "$PR_ACT" enroll
  run "$PR_ACT" unenroll
  [ "$status" -eq 0 ]
  [ -z "$(git config branch.feat.pr-tend || true)" ]
}

@test "unenroll: a branch that was never enrolled is fine" {
  run "$PR_ACT" unenroll
  [ "$status" -eq 0 ]
}

@test "forget: unenrolls and deletes refs/pr-tend/<branch>/*" {
  "$PR_ACT" enroll
  git update-ref refs/pr-tend/feat/base HEAD
  git update-ref refs/pr-tend/feat/local HEAD
  run "$PR_ACT" forget
  [ "$status" -eq 0 ]
  [ -z "$(git config branch.feat.pr-tend || true)" ]
  [ -z "$(git for-each-ref refs/pr-tend/feat/)" ]
}

@test "forget: a named branch; other branches' pins stay" {
  git switch -qc other
  git update-ref refs/pr-tend/feat/base HEAD
  git update-ref refs/pr-tend/other/base HEAD
  run "$PR_ACT" forget feat
  [ "$status" -eq 0 ]
  [ -z "$(git for-each-ref refs/pr-tend/feat/)" ]
  [ -n "$(git for-each-ref refs/pr-tend/other/)" ]
}

@test "forget: a branch with nothing stored, even one already deleted, is fine" {
  run "$PR_ACT" forget
  [ "$status" -eq 0 ]
  run "$PR_ACT" forget gone
  [ "$status" -eq 0 ]
}

@test "unregister: removes this repo from the watcher's list" {
  "$PR_ACT" enroll && "$PR_ACT" unenroll
  [ "$(repos)" = "$TMP/repo" ]
  run "$PR_ACT" unregister
  [ "$status" -eq 0 ]
  [ -z "$(repos)" ]
}

@test "unregister: refuses while branches are still enrolled; --force overrides" {
  "$PR_ACT" enroll
  run "$PR_ACT" unregister
  [ "$status" -ne 0 ]
  [[ "$output" == *"feat"* ]]
  [ "$(repos)" = "$TMP/repo" ]
  run "$PR_ACT" unregister --force
  [ "$status" -eq 0 ]
  [ -z "$(repos)" ]
}

@test "unregister: a path, for a repo whose directory is gone" {
  "$PR_ACT" enroll
  git config --global --add pr-tend.repo "$TMP/gone"
  run "$PR_ACT" unregister "$TMP/gone"
  [ "$status" -eq 0 ]
  [ "$(repos)" = "$TMP/repo" ]
}

@test "unregister: a repo that isn't registered is fine" {
  run "$PR_ACT" unregister
  [ "$status" -eq 0 ]
}

@test "--help: every verb has a usage line" {
  run "$PR_ACT" --help
  [ "$status" -eq 0 ]
  verbs=$(sed -n '/^case \$verb in/,/^esac/s/^  \([a-z-]*\)).*/\1/p' "$PR_ACT")
  [ -n "$verbs" ]
  for v in $verbs; do
    [[ "$output" =~ pr-act\ $v\  ]] || { echo "missing: $v"; false; }
  done
}

@test "--help works outside a repo" {
  cd "$TMP"
  run "$PR_ACT" --help
  [[ "$output" == *"Usage"* ]]
}

@test "unenroll: a real config error is not swallowed" {
  "$PR_ACT" enroll
  touch .git/config.lock
  run "$PR_ACT" unenroll
  rm -f .git/config.lock
  [ "$status" -ne 0 ]
}
