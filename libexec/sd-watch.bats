#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

# Test suite for libexec/sd-watch (the observe-only watcher pass).
#
# Real git for repos, enrollment and fetch. sd state is faked: it serves
# $PS_FIXTURES/<branch>.json, so each glyph/notification rule can be driven
# directly. Notifications go to a stub configured as sheepdog.notify.

SD_WATCH="$BATS_TEST_DIRNAME/sd-watch"

setup() {
  TMP="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  export GIT_CONFIG_GLOBAL="$TMP/gitconfig-global"
  export GIT_CONFIG_SYSTEM=/dev/null
  printf '[user]\n\temail = t@example.com\n\tname = Tester\n[init]\n\tdefaultBranch = main\n' > "$GIT_CONFIG_GLOBAL"
  export SHEEPDOG_STATE_DIR="$TMP/state"
  export STATUS_DIR="$TMP/status"
  export PS_FIXTURES="$TMP/ps"
  export SHEEPDOG_CONFIG="$TMP/global.json"
  SD_CONFIG="$BATS_TEST_DIRNAME/sd-config"
  mkdir -p "$PS_FIXTURES" "$TMP/fakebin"

  cat > "$TMP/fakebin/sd-state" <<'EOF'
#!/usr/bin/env bash
b=${@: -1}
echo "$PWD $b" >> "$PS_FIXTURES/calls"
f="$PS_FIXTURES/${b//\//__}.json"
[[ -f $f ]] || { echo "sd state: no fixture for $b" >&2; exit 1; }
cat "$f"
EOF
  cat > "$TMP/fakebin/notify" <<'EOF'
#!/usr/bin/env bash
printf '%s|%s\n' "$1" "$2" >> "$PS_FIXTURES/notified"
EOF
  chmod +x "$TMP/fakebin/sd-state" "$TMP/fakebin/notify"
  export PATH="$TMP/fakebin:$PATH"
  # Never the real macOS notifier: every config a test writes keeps this one.
  "$SD_CONFIG" set --global settings.notify "$TMP/fakebin/notify"

  git init -q --bare "$TMP/origin.git"
  git clone -q "$TMP/origin.git" "$TMP/repo" 2>/dev/null
  cd "$TMP/repo"
  git commit -q --allow-empty -m init && git push -q origin main 2>/dev/null
  git switch -qc feat
  enroll feat
}

enroll() { git -C "$TMP/repo" config "branch.$1.sheepdog" true; register "$TMP/repo"; }
register() {
  grep -qxF "$1" <<<"$(git config --global --get-all sheepdog.repo || true)" \
    || git config --global --add sheepdog.repo "$1"
}

# ps_fixture <branch> [jq-assignments...] — sd state's JSON. Default: ready to merge.
# .next comes from the real lib/next.sh, as in sd state, unless an assignment sets it.
ps_fixture() {
  local b=$1; shift
  local j
  j=$(jq -n --arg b "$b" '{
    branch: $b, pr: {number: 7, state: "OPEN", draft: false, merge_state: "CLEAN", review_decision: null, review_requests: []},
    parent: {name: "main", merged: false},
    sync: {target: "main", default: "main", behind: 0, up_to_date: true, conflict: false},
    push: {remote_sha: "abc", ahead: 0, behind: 0, diverged: false, remote_ours: true},
    fresh: true, stale: [],
    ci: {verdict: "green", failing: [], pending: [], for_head: true},
    review: {local: {status: "covered"}, bot: {status: "none"}, accepted: {status: "none"}},
    threads: {owed_bot: 0, owed_human: 0, outdated: 0, blocking: 0, info: 0, items: []},
    session: {enrolled: true, locked: false}, errors: []}')
  local a
  for a; do j=$(jq "$a" <<<"$j"); done
  if [[ $(jq 'has("next")' <<<"$j") == false ]]; then
    j=$(jq --argjson n "$(printf '%s\n' "$j" | bash5 -c 'source "$1/../lib/config.sh" && source "$1/../lib/next.sh" && prn_next origin' _ "$BATS_TEST_DIRNAME")" \
          '. + {next: $n}' <<<"$j")
  fi
  printf '%s\n' "$j" > "$PS_FIXTURES/${b//\//__}.json"
}

pass() { (cd "$TMP" && "$SD_WATCH") || { echo "pass failed"; return 1; }; }
glyph() { cut -f2 "$STATUS_DIR/$1.pr"; }
notified() { cat "$PS_FIXTURES/notified" 2>/dev/null || true; }

# ── basics ───────────────────────────────────────────────────────────────────

@test "runs under bash 5 via the bash5 shebang" {
  run head -1 "$SD_WATCH"
  [ "$output" = "#!/usr/bin/env bash5" ]
}

@test "no registered repos: nothing to do, exit 0" {
  git config --global --unset-all sheepdog.repo
  pass
  [ ! -e "$PS_FIXTURES/calls" ]
}

@test "only enrolled branches are checked, from the repo directory" {
  git branch other
  ps_fixture feat
  pass
  [ "$(cat "$PS_FIXTURES/calls")" = "$TMP/repo feat" ]
}

@test "a registered repo that no longer exists is skipped" {
  register "$TMP/gone"
  ps_fixture feat
  pass
  [ "$(cat "$PS_FIXTURES/calls")" = "$TMP/repo feat" ]
}

@test "fetches before checking" {
  git clone -q "$TMP/origin.git" "$TMP/other" 2>/dev/null
  git -C "$TMP/other" commit -q --allow-empty -m moved && git -C "$TMP/other" push -q origin main 2>/dev/null
  ps_fixture feat
  pass
  [ "$(git rev-parse origin/main)" = "$(git -C "$TMP/other" rev-parse main)" ]
}

@test "one branch's sd state failing doesn't stop the others" {
  git branch other && enroll other
  ps_fixture other
  pass
  [ -f "$SHEEPDOG_STATE_DIR/last-pass" ]
  grep -q "other" "$SHEEPDOG_STATE_DIR/last-pass" || false
  grep -q "feat.*sd state failed" "$SHEEPDOG_STATE_DIR/last-pass"
}

# ── glyph ────────────────────────────────────────────────────────────────────

@test "glyph is written for the worktree the branch is checked out in, with the branch" {
  ps_fixture feat
  pass
  [ "$(cat "$STATUS_DIR/repo.pr")" = "feat	✅" ]
}

@test "glyph follows a linked worktree" {
  git switch -q main
  git worktree add -q "$TMP/feat-wt" feat
  ps_fixture feat
  pass
  [ "$(glyph feat-wt)" = "✅" ]
  [ ! -e "$STATUS_DIR/repo.pr" ]
}

@test "a branch checked out nowhere gets no glyph but is still checked" {
  git switch -q main
  ps_fixture feat
  pass
  [ ! -e "$STATUS_DIR/repo.pr" ]
  grep -q feat "$SHEEPDOG_STATE_DIR/last-pass"
}

@test "a glyph left from a branch no longer enrolled is removed" {
  ps_fixture feat
  pass
  git config --unset branch.feat.sheepdog
  pass
  [ ! -e "$STATUS_DIR/repo.pr" ]
}

@test "a pass sweeps refs/sheepdog/<b>/* whose branch no longer exists" {
  git update-ref refs/sheepdog/feat/base HEAD
  git update-ref refs/sheepdog/gone/base HEAD
  git update-ref refs/sheepdog/gone/local HEAD
  git update-ref refs/sheepdog/also/gone/accepted HEAD
  ps_fixture feat
  pass
  [ -n "$(git for-each-ref refs/sheepdog/feat/)" ]
  [ -z "$(git for-each-ref refs/sheepdog/gone/)" ]
  [ -z "$(git for-each-ref refs/sheepdog/also/)" ]
}

@test "the sweep keeps the pins of a branch that exists but isn't enrolled" {
  git switch -qc parked && git switch -q feat
  git update-ref refs/sheepdog/parked/base HEAD
  ps_fixture feat
  pass
  [ -n "$(git for-each-ref refs/sheepdog/parked/)" ]
}

@test "glyph: CI red, conflict, human items, foreign push are ❌" {
  local a
  for a in '.ci.verdict = "red"' '.sync.up_to_date = false | .sync.conflict = true' \
           '.threads.owed_human = 1' '.push.behind = 1 | .push.theirs = 1 | .push.remote_ours = false'; do
    ps_fixture feat "$a"
    pass
    [ "$(glyph repo)" = "❌" ] || { echo "for: $a"; return 1; }
  done
}

@test "glyph: work an agent will do later is 🔧" {
  local a
  for a in '.sync.up_to_date = false | .sync.behind = 2 | .sync.target = "base"' \
           '.sync.up_to_date = false | .parent.merged = true' '.threads.owed_bot = 1' \
           '.push.ahead = 1' '.pr = null' '.review.local.status = "uncovered"'; do
    ps_fixture feat "$a"
    pass
    [ "$(glyph repo)" = "🔧" ] || { echo "for: $a"; return 1; }
  done
}

@test "glyph: CI pending is ⏳" {
  ps_fixture feat '.ci.verdict = "pending"'
  pass
  [ "$(glyph repo)" = "⏳" ]
}

@test "glyph: unknown state (errors, not fresh) is ⚠️" {
  ps_fixture feat '.errors = ["gh: down"] | .fresh = null'
  pass
  [ "$(glyph repo)" = "⚠️" ]
}

@test "glyph: merged 🏁, closed 🚫" {
  ps_fixture feat '.pr.state = "MERGED"'
  pass
  [ "$(glyph repo)" = "🏁" ]
  ps_fixture feat '.pr.state = "CLOSED"'
  pass
  [ "$(glyph repo)" = "🚫" ]
}

@test "glyph: only behind the default branch is still ✅" {
  ps_fixture feat '.sync.up_to_date = false | .sync.behind = 40'
  pass
  [ "$(glyph repo)" = "✅" ]
}

@test "glyph: ❌ outranks 🔧" {
  ps_fixture feat '.ci.verdict = "red" | .push.ahead = 3'
  pass
  [ "$(glyph repo)" = "❌" ]
}

@test "glyph: cancelled checks are 🔧, CI for an older commit is ⏳" {
  ps_fixture feat '.ci.verdict = "inconclusive"'
  pass
  [ "$(glyph repo)" = "🔧" ]
  ps_fixture feat '.ci.for_head = false'
  pass
  [ "$(glyph repo)" = "⏳" ]
}

@test "glyph: a repo with no checks at all can be ready" {
  ps_fixture feat '.ci.verdict = "none" | .ci.for_head = true'
  pass
  [ "$(glyph repo)" = "✅" ]
}

@test "glyph: follows sd state's next steps, not its raw fields" {
  ps_fixture feat '.next = [{key: "ci-wait", who: "wait", say: "CI running", cmd: null}]'
  pass
  [ "$(glyph repo)" = "⏳" ]
  ps_fixture feat '.next = [{key: "bot", who: "agent", say: "address 1 bot item", cmd: null}]'
  pass
  [ "$(glyph repo)" = "🔧" ]
}

@test "glyph: info-only bot items, waiting on chrismo's read, are 🔧" {
  ps_fixture feat '.threads.owed_bot = 1 | .threads.info = 1'
  pass
  [ "$(glyph repo)" = "🔧" ]
  [ -z "$(notified)" ]
}

@test "glyph: sd state output with no next steps is ⚠️" {
  ps_fixture feat '.next = null'
  pass
  [ "$(glyph repo)" = "⚠️" ]
  grep -q "feat.*no next steps" "$SHEEPDOG_STATE_DIR/last-pass"
}

@test "glyph: waiting on a required review is ⏳, never ✅" {
  ps_fixture feat '.pr.merge_state = "BLOCKED" | .pr.review_decision = "REVIEW_REQUIRED" | .pr.review_requests = ["alice"]'
  pass
  [ "$(glyph repo)" = "⏳" ]
  [ -z "$(notified)" ]
}

@test "glyph: GitHub blocking the merge for another reason is 🔧, never ✅" {
  ps_fixture feat '.pr.merge_state = "BLOCKED"'
  pass
  [ "$(glyph repo)" = "🔧" ]
  [ -z "$(notified)" ]
}

@test "glyph: a draft is never ready" {
  ps_fixture feat '.pr.draft = true'
  pass
  [ "$(glyph repo)" = "🔧" ]
  [ -z "$(notified)" ]
}

@test "glyph: sd state failing shows ⚠️ instead of dropping the glyph" {
  ps_fixture feat
  pass
  rm "$PS_FIXTURES/feat.json"
  pass
  [ "$(glyph repo)" = "⚠️" ]
}

@test "unparseable sd state output is ⚠️, and the next good pass still notifies" {
  printf 'warning: junk\n{"branch":' > "$PS_FIXTURES/feat.json"
  pass
  [ "$(glyph repo)" = "⚠️" ]
  grep -q "feat.*unparseable" "$SHEEPDOG_STATE_DIR/last-pass" || false
  ps_fixture feat '.ci.verdict = "red" | .ci.failing = ["lint"]'
  pass
  [ "$(notified)" = "repo feat|fix CI: lint" ]
}

@test "sd state stderr on success doesn't corrupt its JSON" {
  ps_fixture feat
  cat > "$TMP/fakebin/sd-state" <<'SH'
#!/usr/bin/env bash
echo "warning: something" >&2
cat "$PS_FIXTURES/${@: -1}.json"
SH
  pass
  [ "$(glyph repo)" = "✅" ]
}

@test "a hung sd state times out instead of stalling the pass" {
  git branch other && enroll other
  ps_fixture other
  cat > "$TMP/fakebin/sd-state" <<'SH'
#!/usr/bin/env bash
[[ ${@: -1} == feat ]] && sleep 30
cat "$PS_FIXTURES/${@: -1}.json"
SH
  SECONDS=0
  SHEEPDOG_WATCH_TIMEOUT=1 pass
  (( SECONDS < 10 )) || false
  grep -q "feat.*sd state failed" "$SHEEPDOG_STATE_DIR/last-pass" || false
  grep -q "other.*✅" "$SHEEPDOG_STATE_DIR/last-pass"
}

@test "a failed state write leaves no temp file behind" {
  local real
  real=$(bash5 -c 'source "$1/../lib/config.sh"; command -v "$(prc_superdb_binary)"' _ "$BATS_TEST_DIRNAME")
  [[ $real != */shims/* ]] || skip "super is an asdf shim, which the fake's ASDF_DATA_DIR would break"
  cat > "$TMP/fakebin/super" <<EOF
#!/usr/bin/env bash
for a; do [[ \$a == *"state: s"* ]] && { echo '{"partial":'; exit 1; }; done
exec "$real" "\$@"
EOF
  chmod +x "$TMP/fakebin/super"
  export ASDF_DATA_DIR="$TMP/no-asdf"
  ps_fixture feat
  run --separate-stderr pass
  [[ "$stderr" == *"couldn't save"*"feat.json"* ]] || false
  [ -d "$SHEEPDOG_STATE_DIR/branches" ]
  [ -z "$(find "$SHEEPDOG_STATE_DIR/branches" -name '*.tmp')" ]
  [ -z "$(find "$SHEEPDOG_STATE_DIR/branches" -name 'feat.json')" ]
}

@test "a failed fetch keeps git's reason" {
  git remote set-url origin "$TMP/nowhere.git"
  ps_fixture feat
  pass
  grep -q "fetch from origin failed: .*nowhere" "$SHEEPDOG_STATE_DIR/last-pass"
}

# ── notifications ────────────────────────────────────────────────────────────

@test "notify: ready to merge, once" {
  ps_fixture feat
  pass
  pass
  [ "$(notified)" = "repo feat|ready to merge" ]
}

@test "notify: CI red names the failing checks" {
  ps_fixture feat '.ci.verdict = "red" | .ci.failing = ["lint", "test"]'
  pass
  [ "$(notified)" = "repo feat|fix CI: lint, test" ]
}

@test "notify: a reason that clears and comes back notifies again" {
  ps_fixture feat '.ci.verdict = "red" | .ci.failing = ["lint"]'
  pass
  ps_fixture feat '.ci.verdict = "pending"'
  pass
  ps_fixture feat '.ci.verdict = "red" | .ci.failing = ["lint"]'
  pass
  [ "$(notified | grep -c 'fix CI')" = 2 ]
}

@test "notify: agent-later work and pending CI stay quiet" {
  ps_fixture feat '.ci.verdict = "pending" | .push.ahead = 1 | .threads.owed_bot = 2'
  pass
  [ -z "$(notified)" ]
}

@test "notify: human items, conflict, foreign push, merged" {
  ps_fixture feat '.threads.owed_human = 2'
  pass
  ps_fixture feat '.sync.up_to_date = false | .sync.conflict = true'
  pass
  ps_fixture feat '.push.behind = 1 | .push.theirs = 1 | .push.remote_ours = false'
  pass
  ps_fixture feat '.pr.state = "MERGED"'
  pass
  run notified
  [ "${lines[0]}" = "repo feat|reply to 2 human items" ]
  [ "${lines[1]}" = "repo feat|restack onto main conflicts: resolve it" ]
  [ "${lines[2]}" = "repo feat|origin/feat has 1 commit this copy has never had" ]
  [ "${lines[3]}" = "repo feat|merged: drop the branch's pins and enrollment, then remove this worktree" ]
}

# ── a branch deleted with its state left behind (#64) ───────────────────────

# gh_pull <json>: what the fake gh serves for GET repos/{owner}/{repo}/pulls/<n>.
gh_pull() {
  printf '%s\n' "$1" > "$PS_FIXTURES/gh-pull"
  cat > "$TMP/fakebin/gh" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$PS_FIXTURES/gh-calls"
[[ -f $PS_FIXTURES/gh-pull ]] || { echo "gh: API rate limit exceeded" >&2; exit 1; }
cat "$PS_FIXTURES/gh-pull"
SH
  chmod +x "$TMP/fakebin/gh"
}

# gone <branch>: what gh pr merge --delete-branch does from the branch's checkout.
gone() { git switch -q main && git branch -qD "$1"; }

state_files() { find "$SHEEPDOG_STATE_DIR/branches" -name '*.json' 2>/dev/null; }

@test "gone: an enrolled branch deleted after its PR merged is notified merged once, and its state dropped" {
  ps_fixture feat '.ci.verdict = "pending"'
  pass
  gone feat
  gh_pull '{"state": "closed", "merged": true}'
  pass
  [ "$(notified)" = "repo feat|merged (#7); the local branch is already gone" ]
  grep -q "feat.*🏁.*merged (#7)" "$SHEEPDOG_STATE_DIR/last-pass"
  [ -z "$(state_files)" ]
  pass
  [ "$(notified | wc -l | tr -d ' ')" = 1 ]
  [ "$(cat "$PS_FIXTURES/gh-calls")" = "api repos/{owner}/{repo}/pulls/7" ]
}

@test "gone: a merge already notified before the branch went isn't notified again" {
  ps_fixture feat '.pr.state = "MERGED"'
  pass
  gone feat
  gh_pull '{"state": "closed", "merged": true}'
  pass
  [ "$(notified | grep -c merged)" = 1 ]
  [ -z "$(state_files)" ]
}

@test "gone: a branch with a slash in its name is found" {
  git switch -qc 12/doc && enroll 12/doc
  ps_fixture 12/doc '.ci.verdict = "pending"'
  pass
  gone 12/doc
  gh_pull '{"state": "closed", "merged": true}'
  pass
  [[ "$(notified)" == *"repo 12/doc|merged (#7)"* ]] || false
  [ -z "$(state_files | grep doc)" ]
}

@test "gone: GitHub not answering keeps the state, and the next pass tries again" {
  ps_fixture feat '.ci.verdict = "pending"'
  pass
  gone feat
  gh_pull '{}' && rm "$PS_FIXTURES/gh-pull"
  pass
  grep -q "feat.*⚠️.*branch is gone; GitHub didn't say what became of #7" "$SHEEPDOG_STATE_DIR/last-pass"
  [ -n "$(state_files)" ]
  [ -z "$(notified)" ]
  gh_pull '{"state": "closed", "merged": true}'
  pass
  [ "$(notified)" = "repo feat|merged (#7); the local branch is already gone" ]
}

@test "gone: a PR that wasn't merged drops the state quietly" {
  ps_fixture feat '.ci.verdict = "pending"'
  pass
  gone feat
  gh_pull '{"state": "closed", "merged": false}'
  pass
  [ -z "$(notified)" ]
  [ -z "$(state_files)" ]
  grep -q "feat.*branch is gone; #7 is closed, not merged" "$SHEEPDOG_STATE_DIR/last-pass"
}

@test "gone: a branch that never had a PR drops the state without asking GitHub" {
  ps_fixture feat '.pr = null'
  pass
  gone feat
  gh_pull '{"state": "closed", "merged": true}'
  pass
  [ -z "$(state_files)" ]
  [ ! -e "$PS_FIXTURES/gh-calls" ]
}

@test "gone: a branch that still exists but isn't enrolled keeps its state" {
  ps_fixture feat
  pass
  git config --unset branch.feat.sheepdog
  gh_pull '{"state": "closed", "merged": true}'
  pass
  [ -n "$(state_files)" ]
  [ ! -e "$PS_FIXTURES/gh-calls" ]
}

# ── notification policy (#52) ────────────────────────────────────────────────

# policy n|q: the step keys sd watch --help lists as notified (n) or not (q).
policy() {
  "$SD_WATCH" --help | awk -v want="$1" '
    /^Notified/ { m = "n"; next }
    /^Not notified/ { m = "q"; next }
    /^[^ ]/ { m = "" }
    m == want && /^  [a-z][a-z -]*:/ { sub(/^ +/, ""); sub(/:.*/, ""); print }' | tr ' ' '\n' | grep .
}

# one_step <key>: sd state's next is that single step, said as "say <key>".
one_step() {
  ps_fixture feat ".next = [{key: \"$1\", who: \"you\", say: \"say $1\", cmd: null}]"
}

@test "policy: every lib/next.sh step is in --help, notified or not, exactly once" {
  local steps listed
  steps=$(grep -o 'step("[a-z-]*"' "$BATS_TEST_DIRNAME/../lib/next.sh" | sed 's/step("//; s/"//' | sort -u)
  listed=$( { policy n; policy q; } | sort)
  [ -n "$(policy n)" ]
  diff <(echo "$steps") <(echo "$listed")
}

@test "policy: a notified step notifies once on entering it, not on later passes" {
  local k
  for k in $(policy n); do
    rm -rf "$SHEEPDOG_STATE_DIR" "$PS_FIXTURES/notified"
    one_step "$k"
    pass
    pass
    pass
    [ "$(notified)" = "repo feat|say $k" ] || { echo "for $k: $(notified)"; return 1; }
  done
}

@test "policy: a step that isn't notified never is" {
  local k
  for k in $(policy q); do
    rm -rf "$SHEEPDOG_STATE_DIR"
    one_step "$k"
    pass
    [ -z "$(notified)" ] || { echo "for $k: $(notified)"; return 1; }
  done
}

@test "policy: a parent closed without merging is ❌ and notifies" {
  ps_fixture feat '.pr.base = "par" | .parent = {name: "par", merged: false, pr: {number: 5, state: "CLOSED"}}'
  pass
  [ "$(glyph repo)" = "❌" ]
  [[ "$(notified)" == "repo feat|par (#5) was closed without merging"* ]]
}

@test "notify: a conflict after CI red was notified still notifies, once" {
  ps_fixture feat '.ci.verdict = "red" | .ci.failing = ["lint"]'
  pass
  ps_fixture feat '.ci.verdict = "red" | .ci.failing = ["lint"] | .sync.up_to_date = false | .sync.conflict = true'
  pass
  pass
  run notified
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[0]}" = "repo feat|fix CI: lint" ]
  [ "${lines[1]}" = "repo feat|restack onto main conflicts: resolve it" ]
}

@test "notify: a conflict after ready to merge was notified still notifies, once" {
  ps_fixture feat
  pass
  ps_fixture feat '.sync.up_to_date = false | .sync.conflict = true'
  pass
  pass
  run notified
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[1]}" = "repo feat|restack onto main conflicts: resolve it" ]
}

@test "notify: an unknown pass (sd state errors) between two doesn't re-notify what's still true" {
  ps_fixture feat '.sync.up_to_date = false | .sync.conflict = true'
  pass
  ps_fixture feat '.errors = ["gh: down"]'
  pass
  [ "$(glyph repo)" = "⚠️" ]
  ps_fixture feat '.sync.up_to_date = false | .sync.conflict = true'
  pass
  [ "$(notified)" = "repo feat|restack onto main conflicts: resolve it" ]
}

@test "notify: errors alongside a ❌ step still keep what was notified" {
  ps_fixture feat '.ci.verdict = "red" | .ci.failing = ["lint"] | .threads.owed_human = 1'
  pass
  ps_fixture feat '.ci.verdict = "red" | .ci.failing = ["lint"] | .errors = ["gh: down"]'
  pass
  [ "$(glyph repo)" = "❌" ]
  ps_fixture feat '.ci.verdict = "red" | .ci.failing = ["lint"] | .threads.owed_human = 1'
  pass
  [ "$(notified | grep -c 'human item')" = 1 ]
}

@test "notify: a state file from before notified was recorded doesn't re-notify" {
  ps_fixture feat
  pass
  local f; f=$(find "$SHEEPDOG_STATE_DIR/branches" -name feat.json)
  jq -c 'del(.notified)' "$f" > "$f.old" && mv "$f.old" "$f"
  pass
  [ "$(notified)" = "repo feat|ready to merge" ]
}

@test "notify: sd state failing between two passes doesn't re-notify what's still true" {
  ps_fixture feat '.sync.up_to_date = false | .sync.conflict = true'
  pass
  mv "$PS_FIXTURES/feat.json" "$TMP/feat.json"
  pass
  mv "$TMP/feat.json" "$PS_FIXTURES/feat.json"
  pass
  [ "$(notified)" = "repo feat|restack onto main conflicts: resolve it" ]
}

@test "notify: a pass with no next steps between two doesn't re-notify what's still true" {
  ps_fixture feat '.sync.up_to_date = false | .sync.conflict = true'
  pass
  ps_fixture feat '.next = []'
  pass
  [ "$(glyph repo)" = "⚠️" ]
  ps_fixture feat '.sync.up_to_date = false | .sync.conflict = true'
  pass
  [ "$(notified)" = "repo feat|restack onto main conflicts: resolve it" ]
}

@test "notify: a reason the pass couldn't send because super failed is sent next pass" {
  local real
  real=$(bash5 -c 'source "$1/../lib/config.sh"; command -v "$(prc_superdb_binary)"' _ "$BATS_TEST_DIRNAME")
  [[ $real != */shims/* ]] || skip "super is an asdf shim, which the fake's ASDF_DATA_DIR would break"
  ps_fixture feat '.sync.up_to_date = false | .sync.conflict = true'
  cat > "$TMP/fakebin/super" <<EOF
#!/usr/bin/env bash
if [[ ! -e $PS_FIXTURES/super-works ]]; then
  for a; do [[ \$a == *"r.msg}"* ]] && { echo panic >&2; exit 2; }; done
fi
exec "$real" "\$@"
EOF
  chmod +x "$TMP/fakebin/super"
  export ASDF_DATA_DIR="$TMP/no-asdf"
  pass
  [ -z "$(notified)" ]
  touch "$PS_FIXTURES/super-works"
  pass
  pass
  [ "$(notified)" = "repo feat|restack onto main conflicts: resolve it" ]
}

@test "notify: a notification that fails is tried again next pass, then not again" {
  cat > "$TMP/fakebin/notify" <<'SH'
#!/usr/bin/env bash
[[ -e $PS_FIXTURES/notify-works ]] || exit 1
printf '%s|%s\n' "$1" "$2" >> "$PS_FIXTURES/notified"
SH
  ps_fixture feat '.sync.up_to_date = false | .sync.conflict = true'
  run --separate-stderr pass
  [[ "$stderr" == *"notify failed"* ]] || false
  [ -z "$(notified)" ]
  touch "$PS_FIXTURES/notify-works"
  pass
  pass
  [ "$(notified)" = "repo feat|restack onto main conflicts: resolve it" ]
}

@test "notify: a notifier that keeps failing is tried twice, then given up on" {
  cat > "$TMP/fakebin/notify" <<'SH'
#!/usr/bin/env bash
echo "$2" >> "$PS_FIXTURES/attempts"
exit 1
SH
  ps_fixture feat '.sync.up_to_date = false | .sync.conflict = true'
  pass
  run --separate-stderr pass
  [[ "$stderr" == *"giving up on: restack onto main conflicts"* ]] || false
  pass
  pass
  [ "$(wc -l < "$PS_FIXTURES/attempts" | tr -d ' ')" = 2 ]
}

@test "notify: GitHub recomputing mergeability doesn't make ready re-notify" {
  ps_fixture feat
  pass
  one_step merge-wait
  pass
  ps_fixture feat
  pass
  [ "$(notified)" = "repo feat|ready to merge" ]
}

@test "notify: an attached session hiding ready doesn't make ready re-notify" {
  ps_fixture feat
  pass
  one_step attached
  pass
  ps_fixture feat
  pass
  [ "$(notified)" = "repo feat|ready to merge" ]
}

@test "notify: merge-wait doesn't reset a failed ready's one retry" {
  cat > "$TMP/fakebin/notify" <<'SH'
#!/usr/bin/env bash
echo "$2" >> "$PS_FIXTURES/attempts"
exit 1
SH
  local i
  for i in 1 2 3; do
    ps_fixture feat
    pass
    one_step merge-wait
    pass
  done
  [ "$(wc -l < "$PS_FIXTURES/attempts" | tr -d ' ')" = 2 ]
}

@test "notify: merge-wait carries only ready: a conflict that comes back after it notifies" {
  ps_fixture feat '.sync.up_to_date = false | .sync.conflict = true'
  pass
  one_step merge-wait
  pass
  ps_fixture feat '.sync.up_to_date = false | .sync.conflict = true'
  pass
  [ "$(notified | grep -c conflicts)" = 2 ]
}

@test "notify: an unsure pass doesn't reset a failed notification's one retry" {
  cat > "$TMP/fakebin/notify" <<'SH'
#!/usr/bin/env bash
echo "$2" >> "$PS_FIXTURES/attempts"
exit 1
SH
  ps_fixture feat '.sync.up_to_date = false | .sync.conflict = true'
  pass
  ps_fixture feat '.errors = ["gh: down"]'
  pass
  ps_fixture feat '.sync.up_to_date = false | .sync.conflict = true'
  pass
  pass
  [ "$(wc -l < "$PS_FIXTURES/attempts" | tr -d ' ')" = 2 ]
}

@test "notify: a notifier that reads stdin doesn't swallow later reasons" {
  cat > "$TMP/fakebin/notify" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
printf '%s|%s\n' "$1" "$2" >> "$PS_FIXTURES/notified"
SH
  ps_fixture feat '.ci.verdict = "red" | .ci.failing = ["lint"] | .threads.owed_human = 1'
  pass
  [ "$(notified | wc -l | tr -d ' ')" = 2 ]
}

@test "notify: notifier output stays out of the pass record" {
  cat > "$TMP/fakebin/notify" <<'SH'
#!/usr/bin/env bash
echo "NOISE"
SH
  ps_fixture feat
  pass
  ! grep -q NOISE "$SHEEPDOG_STATE_DIR/last-pass"
}

@test "notify: a configured command with a space in its path works" {
  mkdir -p "$TMP/my tools"
  cp "$TMP/fakebin/notify" "$TMP/my tools/notify"
  "$SD_CONFIG" set --global settings.notify "'$TMP/my tools/notify'"
  ps_fixture feat
  pass
  [ "$(notified)" = "repo feat|ready to merge" ]
}

# ── status ───────────────────────────────────────────────────────────────────

@test "status: prints the last pass" {
  ps_fixture feat '.ci.verdict = "red" | .ci.failing = ["lint"]'
  pass
  run "$SD_WATCH" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"repo"*"feat"*"❌"*"fix CI: lint"* ]] || false
  [[ "$output" != *$'\t'* ]]
}

@test "status: before any pass" {
  run "$SD_WATCH" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"no pass yet"* ]]
}

# ── refresh ──────────────────────────────────────────────────────────────────

refresh() { "$SD_WATCH" refresh "$@"; }

@test "refresh: checks only the current branch, from the main worktree" {
  git branch other && enroll other
  ps_fixture feat
  ps_fixture other
  run refresh
  [ "$status" -eq 0 ]
  [ "$(cat "$PS_FIXTURES/calls")" = "$TMP/repo feat" ]
  [[ "$output" == *"repo  feat  ✅  ready to merge"* ]]
}

@test "refresh <branch>: checks that branch" {
  git branch other && enroll other
  ps_fixture other '.ci.verdict = "red" | .ci.failing = ["lint"]'
  refresh other
  [ "$(cat "$PS_FIXTURES/calls")" = "$TMP/repo other" ]
  [ "$(notified)" = "repo other|fix CI: lint" ]
}

@test "refresh: writes the glyph and notifies, and a later pass doesn't notify again" {
  ps_fixture feat '.ci.verdict = "red" | .ci.failing = ["lint"]'
  refresh
  [ "$(glyph repo)" = "❌" ]
  pass
  refresh
  [ "$(notified)" = "repo feat|fix CI: lint" ]
}

@test "refresh: after a pass, doesn't notify what the pass did" {
  ps_fixture feat
  pass
  refresh
  [ "$(notified)" = "repo feat|ready to merge" ]
}

@test "refresh: from a linked worktree, its branch and the pass's state" {
  git switch -q main
  git worktree add -q "$TMP/feat-wt" feat
  ps_fixture feat
  (cd "$TMP/feat-wt" && "$SD_WATCH" refresh)
  [ "$(glyph feat-wt)" = "✅" ]
  [ "$(cat "$PS_FIXTURES/calls")" = "$TMP/repo feat" ]
  pass
  [ "$(notified)" = "repo feat|ready to merge" ]
}

@test "refresh: fetches the configured remote" {
  git clone -q "$TMP/origin.git" "$TMP/other" 2>/dev/null
  git -C "$TMP/other" commit -q --allow-empty -m moved && git -C "$TMP/other" push -q origin main 2>/dev/null
  git remote add up "$TMP/origin.git"
  write_cfg '{"settings":{"remote":"up"}}'
  ps_fixture feat
  refresh
  [ "$(git rev-parse up/main)" = "$(git -C "$TMP/other" rev-parse main)" ]
}

@test "refresh: a failed fetch is reported and the branch still checked" {
  git remote set-url origin "$TMP/nowhere.git"
  ps_fixture feat
  run refresh
  [ "$status" -eq 0 ]
  [[ "$output" == *"fetch from origin failed: "*"nowhere"* ]] || false
  [ "$(glyph repo)" = "✅" ]
}

@test "refresh: isn't recorded as a pass, and leaves other glyphs alone" {
  git branch other && enroll other
  git worktree add -q "$TMP/other-wt" other
  ps_fixture feat '.ci.verdict = "red" | .ci.failing = ["lint"]'
  ps_fixture other
  pass
  local before; before=$(cat "$SHEEPDOG_STATE_DIR/last-pass")
  ps_fixture feat
  refresh
  [ "$(cat "$SHEEPDOG_STATE_DIR/last-pass")" = "$before" ]
  [ "$(glyph other-wt)" = "✅" ]
  [ "$(glyph repo)" = "✅" ]
}

@test "refresh: before any pass, status still says so" {
  ps_fixture feat
  refresh
  run "$SD_WATCH" status
  [[ "$output" == *"no pass yet"* ]]
}

@test "refresh: sd state failing is ⚠️ and exits non-zero" {
  run refresh
  [ "$status" -ne 0 ]
  [[ "$output" == *"feat  ⚠️  sd state failed"* ]] || false
  [ "$(glyph repo)" = "⚠️" ]
}

@test "refresh: unparseable sd state output is ⚠️ and exits non-zero" {
  printf 'warning: junk\n{"branch":' > "$PS_FIXTURES/feat.json"
  run refresh
  [ "$status" -ne 0 ]
  [[ "$output" == *"feat  ⚠️  unparseable"* ]]
}

@test "refresh: an unreadable config file exits non-zero without checking" {
  ps_fixture feat
  printf '{not json\n' > "$SHEEPDOG_CONFIG"
  run refresh
  [ "$status" -ne 0 ]
  [[ "$output" == *"sd config failed"* ]] || false
  [ ! -e "$PS_FIXTURES/calls" ]
}

@test "refresh: refuses a branch that isn't enrolled, or doesn't exist" {
  git branch other
  run refresh other
  [ "$status" -ne 0 ]
  [[ "$output" == *"other isn't enrolled"*"sd act enroll"* ]] || false
  run refresh nope
  [ "$status" -ne 0 ]
  [[ "$output" == *"no such branch: nope"* ]] || false
  [ ! -e "$PS_FIXTURES/calls" ]
}

@test "refresh: -h prints the help; another option or a second branch is refused" {
  run refresh -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: sd watch"* ]] || false
  run refresh --nope
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown option: --nope"* ]] || false
  git branch other && enroll other
  run refresh feat other
  [ "$status" -ne 0 ]
  [[ "$output" == *"usage: sd watch refresh [<branch>]"* ]] || false
  [ ! -e "$PS_FIXTURES/calls" ]
}

@test "refresh: refuses a repo the pass doesn't watch" {
  git config --global --unset-all sheepdog.repo
  ps_fixture feat
  run refresh
  [ "$status" -ne 0 ]
  [[ "$output" == *"$TMP/repo isn't registered"*"sd act enroll"* ]] || false
  [ ! -e "$PS_FIXTURES/calls" ]
}

@test "refresh: refuses a detached HEAD with no branch named" {
  git switch -q --detach
  run refresh
  [ "$status" -ne 0 ]
  [[ "$output" == *"not on a branch"* ]]
}

@test "refresh: outside a git repo, refuses" {
  cd "$TMP"
  run refresh
  [ "$status" -ne 0 ]
  [[ "$output" == *"not in a git repository"* ]]
}

# ── launchd ──────────────────────────────────────────────────────────────────

# Not in setup_launchd: tests refused before plutil runs should still run on Linux.
needs_plutil() {
  command -v plutil >/dev/null || skip "needs plutil (macOS)"
}

setup_launchd() {
  export SHEEPDOG_WATCH_LAUNCH_AGENTS="$TMP/LaunchAgents"
  cat > "$TMP/fakebin/launchctl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$PS_FIXTURES/launchctl"
EOF
  chmod +x "$TMP/fakebin/launchctl"
  PLIST="$SHEEPDOG_WATCH_LAUNCH_AGENTS/com.sheepdog.watch.plist"
}

OLD_LABELS=(com.agent-rig.pr-watch com.pr-tend.pr-watch)

old_plists() {
  mkdir -p "$SHEEPDOG_WATCH_LAUNCH_AGENTS"
  local l
  for l in "${OLD_LABELS[@]}"; do echo old > "$SHEEPDOG_WATCH_LAUNCH_AGENTS/$l.plist"; done
}

old_labels_retired() {
  local l
  for l in "${OLD_LABELS[@]}"; do
    grep -q "bootout gui/$(id -u)/$l" "$PS_FIXTURES/launchctl"
    [ ! -e "$SHEEPDOG_WATCH_LAUNCH_AGENTS/$l.plist" ]
  done
}

@test "install: writes a valid plist and bootstraps it" {
  needs_plutil
  setup_launchd
  run "$SD_WATCH" install
  [ "$status" -eq 0 ]
  plutil -lint "$PLIST"
  [ "$(plutil -extract StartInterval raw "$PLIST")" = 300 ]
  [[ "$(plutil -extract EnvironmentVariables.PATH raw "$PLIST")" == "$HOME/.local/bin:"* ]]
  grep -q "bootstrap gui/$(id -u) $PLIST" "$PS_FIXTURES/launchctl"
}

@test "install: the job runs sd watch" {
  needs_plutil
  setup_launchd
  run "$SD_WATCH" install
  [ "$status" -eq 0 ]
  [[ "$(plutil -extract ProgramArguments.0 raw "$PLIST")" == */sd ]]
  [ -x "$(plutil -extract ProgramArguments.0 raw "$PLIST")" ]
  [ "$(plutil -extract ProgramArguments.1 raw "$PLIST")" = watch ]
}

@test "uninstall: boots out and removes the plist" {
  needs_plutil
  setup_launchd
  "$SD_WATCH" install
  run "$SD_WATCH" uninstall
  [ "$status" -eq 0 ]
  [ ! -e "$PLIST" ]
  grep -q "bootout gui/$(id -u)/com.sheepdog.watch" "$PS_FIXTURES/launchctl"
}

@test "install: boots out the jobs under the old labels and removes their plists" {
  needs_plutil
  setup_launchd
  old_plists
  run "$SD_WATCH" install
  [ "$status" -eq 0 ]
  old_labels_retired
  [ -e "$PLIST" ]
}

@test "uninstall: also boots out the old labels" {
  needs_plutil
  setup_launchd
  old_plists
  run "$SD_WATCH" uninstall
  [ "$status" -eq 0 ]
  old_labels_retired
}

@test "install: a non-numeric interval is refused and the old job is kept" {
  needs_plutil
  setup_launchd
  "$SD_WATCH" install
  : > "$PS_FIXTURES/launchctl"
  write_cfg '{"settings":{"interval":"5m"}}'
  run "$SD_WATCH" install
  [ "$status" -ne 0 ]
  [ "$(plutil -extract StartInterval raw "$PLIST")" = 300 ]
  [ ! -s "$PS_FIXTURES/launchctl" ]
}

@test "install: paths are XML-escaped" {
  needs_plutil
  setup_launchd
  export SHEEPDOG_STATE_DIR="$TMP/a&b"
  "$SD_WATCH" install
  plutil -lint "$PLIST"
  [ "$(plutil -extract StandardOutPath raw "$PLIST")" = "$TMP/a&b/launchd.log" ]
}

# ── settings via sd config: the global file over the defaults ───────────────

# write_cfg <json>: the global file, keeping the stub notifier unless <json> sets one.
write_cfg() {
  jq -n --arg n "$TMP/fakebin/notify" --argjson c "$1" '{settings: {notify: $n}} * $c' > "$SHEEPDOG_CONFIG"
}

@test "config: git config sheepdog.notify is not read" {
  git config --global sheepdog.notify "$TMP/fakebin/missing"
  ps_fixture feat
  pass
  [ "$(cat "$PS_FIXTURES/notified")" = "repo feat|ready to merge" ]
}

@test "config: a branch file in the working directory does not steer the watcher" {
  write_cfg "{\"settings\":{\"notify\":\"$TMP/fakebin/notify\"}}"
  mkdir -p "$TMP/repo/.git/sheepdog"
  printf '{"settings":{"notify":"%s"}}\n' "$TMP/fakebin/missing" > "$TMP/repo/.git/sheepdog/feat.json"
  ps_fixture feat
  (cd "$TMP/repo" && "$SD_WATCH")
  [ "$(cat "$PS_FIXTURES/notified")" = "repo feat|ready to merge" ]
}

@test "config: remote from the file" {
  write_cfg '{"settings":{"remote":"nowhere"}}'
  ps_fixture feat
  pass
  grep -q "fetch from nowhere failed" "$SHEEPDOG_STATE_DIR/last-pass"
}

@test "config: install reads interval from the file" {
  needs_plutil
  setup_launchd
  write_cfg '{"settings":{"interval":120}}'
  "$SD_WATCH" install
  [ "$(plutil -extract StartInterval raw "$PLIST")" = 120 ]
}

@test "config: a non-numeric interval in the file is refused" {
  setup_launchd
  write_cfg '{"settings":{"interval":"5m"}}'
  run "$SD_WATCH" install
  [ "$status" -ne 0 ]
  [ ! -e "$PLIST" ]
}

@test "config: an unreadable config file is reported for the repo, not silently defaulted" {
  printf '{not json\n' > "$SHEEPDOG_CONFIG"
  ps_fixture feat
  pass
  grep -q "repo.*sd config failed" "$SHEEPDOG_STATE_DIR/last-pass"
  [ ! -f "$PS_FIXTURES/calls" ]
}

@test "config: install refuses when the config file is unreadable" {
  setup_launchd
  printf '{not json\n' > "$SHEEPDOG_CONFIG"
  run "$SD_WATCH" install
  [ "$status" -ne 0 ]
  [ ! -e "$PLIST" ]
}
