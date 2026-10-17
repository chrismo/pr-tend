#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

# Test suite for libexec/sd-act (mechanical pipeline verbs). Only enroll/unenroll
# so far: the config the watcher reads.

SD_ACT="$BATS_TEST_DIRNAME/sd-act"

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

repos() { git config --global --get-all sheepdog.repo || true; }

@test "runs under bash 5 via the bash5 shebang" {
  run head -1 "$SD_ACT"
  [ "$output" = "#!/usr/bin/env bash5" ]
}

@test "no verb: usage on stderr, nonzero" {
  run "$SD_ACT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Usage"* ]]
}

@test "unknown verb fails" {
  run "$SD_ACT" frobnicate
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown verb"* ]]
}

@test "enroll: marks the current branch and registers the repo" {
  run "$SD_ACT" enroll
  [ "$status" -eq 0 ]
  [[ "$output" == *"enrolled feat"* ]]
  [ "$(git config branch.feat.sheepdog)" = true ]
  [ "$(repos)" = "$TMP/repo" ]
}

@test "enroll: a named branch" {
  git branch other
  run "$SD_ACT" enroll other
  [ "$status" -eq 0 ]
  [ "$(git config branch.other.sheepdog)" = true ]
  [ -z "$(git config branch.feat.sheepdog || true)" ]
}

# no_prs: an origin with main on it, sd state on PATH, and a gh with no PRs.
no_prs() {
  git init -q --bare "$TMP/origin.git"
  git remote add origin "$TMP/origin.git"
  git push -q origin HEAD:main 2>/dev/null
  git fetch -q origin
  git remote set-head origin main
  mkdir -p "$TMP/fakebin"
  cat > "$TMP/fakebin/gh" <<'SH'
#!/usr/bin/env bash
echo '{"data":{"viewer":{"login":"me"},"repository":{"defaultBranchRef":{"name":"main"},"pullRequests":{"nodes":[]}}}}'
SH
  chmod +x "$TMP/fakebin/gh"
  export PATH="$BATS_TEST_DIRNAME:$TMP/fakebin:$PATH" SHEEPDOG_CONFIG="$TMP/global.json"
}

@test "enroll: a branch made from another's tip, with no PR, records it as the parent (#94)" {
  git switch -q main && no_prs
  git switch -qc par && git commit -q --allow-empty -m p1
  git switch -qc kid && git commit -q --allow-empty -m k1
  run "$SD_ACT" enroll kid
  [ "$status" -eq 0 ]
  [[ "$output" == *"parent: par"* ]]
  [ "$(git config branch.kid.sd-parent)" = par ]
  [ "$(git rev-parse refs/sheepdog/kid/base)" = "$(git rev-parse par)" ]
}

@test "enroll: two candidate parents record neither, and say so" {
  git switch -q main && no_prs
  git switch -qc par && git commit -q --allow-empty -m p1
  git branch twin
  git switch -qc kid && git commit -q --allow-empty -m k1
  run "$SD_ACT" enroll kid
  [ "$status" -eq 0 ]
  [[ "$output" == *"kid looks stacked on par or twin"*"git config branch.kid.sd-parent"* ]]
  [ -z "$(git config branch.kid.sd-parent || true)" ]
}

@test "enroll: a parent that moved on since: the child records nothing and says so, the parent isn't asked" {
  git switch -q main && no_prs
  git switch -qc par && git commit -q --allow-empty -m p1
  git switch -qc kid && git commit -q --allow-empty -m k1
  git switch -q par && git commit -q --allow-empty -m p2
  run "$SD_ACT" enroll kid
  [ "$status" -eq 0 ]
  [[ "$output" == *"kid shares commits with par"*"git config branch.kid.sd-parent par"*"git config branch.kid.sd-parent main"* ]]
  [ -z "$(git config branch.kid.sd-parent || true)" ]
  run "$SD_ACT" enroll par
  [ "$status" -eq 0 ]
  [[ "$output" != *"shares commits"* ]]
  [ -z "$(git config branch.par.sd-parent || true)" ]
}

@test "enroll: a PR on the default branch, or gh failing, records no git-inferred parent" {
  git switch -q main && no_prs
  git switch -qc par && git commit -q --allow-empty -m p1
  git switch -qc kid && git commit -q --allow-empty -m k1
  cat > "$TMP/fakebin/gh" <<'SH'
#!/usr/bin/env bash
echo "gh: API rate limit exceeded" >&2; exit 1
SH
  run "$SD_ACT" enroll kid
  [ "$status" -eq 0 ]
  [ -z "$(git config branch.kid.sd-parent || true)" ]
  # One answer for both of sd state's queries: discovery's list and the fetch by number.
  pr='{"number":3,"url":"u","state":"OPEN","isDraft":false,"baseRefName":"main","headRefName":"kid","headRefOid":"'"$(git rev-parse kid)"'",
  "mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","reviewDecision":null,"mergedAt":null}'
  cat > "$TMP/fakebin/gh" <<SH
#!/usr/bin/env bash
cat <<'JSON'
{"data":{"viewer":{"login":"me"},"repository":{"defaultBranchRef":{"name":"main"},"pullRequests":{"nodes":[$pr]},"pullRequest":$pr}}}
JSON
SH
  run "$SD_ACT" enroll kid
  [ "$status" -eq 0 ]
  [ -z "$(git config branch.kid.sd-parent || true)" ]
}

@test "enroll: a branch made from main alone records no parent" {
  git switch -q main && no_prs
  git switch -qc solo && git commit -q --allow-empty -m s1
  run "$SD_ACT" enroll solo
  [ "$status" -eq 0 ]
  [ -z "$(git config branch.solo.sd-parent || true)" ]
}

@test "enroll: a missing branch fails" {
  run "$SD_ACT" enroll nope
  [ "$status" -ne 0 ]
  [[ "$output" == *"no such branch"* ]]
}

@test "enroll: registers the repo only once" {
  "$SD_ACT" enroll
  git branch other
  "$SD_ACT" enroll other
  [ "$(repos | wc -l | tr -d ' ')" = 1 ]
}

@test "enroll: from a linked worktree, registers the main worktree" {
  git switch -q main
  git worktree add -q "$TMP/wt" feat
  cd "$TMP/wt"
  run "$SD_ACT" enroll
  [ "$status" -eq 0 ]
  [ "$(repos)" = "$TMP/repo" ]
}

@test "unenroll: clears the mark" {
  "$SD_ACT" enroll
  run "$SD_ACT" unenroll
  [ "$status" -eq 0 ]
  [ -z "$(git config branch.feat.sheepdog || true)" ]
}

@test "unenroll: a branch that was never enrolled is fine" {
  run "$SD_ACT" unenroll
  [ "$status" -eq 0 ]
}

@test "forget: unenrolls and deletes refs/sheepdog/<branch>/*" {
  "$SD_ACT" enroll
  git update-ref refs/sheepdog/feat/base HEAD
  git update-ref refs/sheepdog/feat/local HEAD
  run "$SD_ACT" forget
  [ "$status" -eq 0 ]
  [ -z "$(git config branch.feat.sheepdog || true)" ]
  [ -z "$(git for-each-ref refs/sheepdog/feat/)" ]
}

@test "forget: a named branch; other branches' pins stay" {
  git switch -qc other
  git update-ref refs/sheepdog/feat/base HEAD
  git update-ref refs/sheepdog/other/base HEAD
  run "$SD_ACT" forget feat
  [ "$status" -eq 0 ]
  [ -z "$(git for-each-ref refs/sheepdog/feat/)" ]
  [ -n "$(git for-each-ref refs/sheepdog/other/)" ]
}

@test "forget: a branch with nothing stored, even one already deleted, is fine" {
  run "$SD_ACT" forget
  [ "$status" -eq 0 ]
  run "$SD_ACT" forget gone
  [ "$status" -eq 0 ]
}

@test "unregister: removes this repo from the watcher's list" {
  "$SD_ACT" enroll && "$SD_ACT" unenroll
  [ "$(repos)" = "$TMP/repo" ]
  run "$SD_ACT" unregister
  [ "$status" -eq 0 ]
  [ -z "$(repos)" ]
}

@test "unregister: refuses while branches are still enrolled; --force overrides" {
  "$SD_ACT" enroll
  run "$SD_ACT" unregister
  [ "$status" -ne 0 ]
  [[ "$output" == *"feat"* ]]
  [ "$(repos)" = "$TMP/repo" ]
  run "$SD_ACT" unregister --force
  [ "$status" -eq 0 ]
  [ -z "$(repos)" ]
}

@test "unregister: a path, for a repo whose directory is gone" {
  "$SD_ACT" enroll
  git config --global --add sheepdog.repo "$TMP/gone"
  run "$SD_ACT" unregister "$TMP/gone"
  [ "$status" -eq 0 ]
  [ "$(repos)" = "$TMP/repo" ]
}

@test "unregister: a repo that isn't registered is fine" {
  run "$SD_ACT" unregister
  [ "$status" -eq 0 ]
}

@test "--help: every verb has a usage line" {
  run "$SD_ACT" --help
  [ "$status" -eq 0 ]
  verbs=$(sed -n '/^case \$verb in/,/^esac/s/^  \([a-z-]*\)).*/\1/p' "$SD_ACT")
  [ -n "$verbs" ]
  for v in $verbs; do
    [[ "$output" =~ sd\ act\ $v\  ]] || { echo "missing: $v"; false; }
  done
}

@test "--help works outside a repo" {
  cd "$TMP"
  run "$SD_ACT" --help
  [[ "$output" == *"Usage"* ]]
}

@test "unenroll: a real config error is not swallowed" {
  "$SD_ACT" enroll
  touch .git/config.lock
  run "$SD_ACT" unenroll
  rm -f .git/config.lock
  [ "$status" -ne 0 ]
}
