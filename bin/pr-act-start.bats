#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

# Test suite for `pr-act start` (A0: a worktree beside this one on a branch of
# the same name, set up by the repo's hook, with the task, parent and base
# recorded and the branch enrolled; then implement) and `pr-act implement`
# (J0: the agent edits in the branch's session, the pipeline commits and runs
# verify).
#
# The worktree half duplicates agent-rig's wt-new (#14): same placement, same
# branch resolution, same hook locations, stdout exactly the path.
#
# Real git (a bare origin, our clone at $TMP/repo, $TMP/other for pushes that
# aren't ours). gh is a stub with no PRs. claude edits through $FX/agent and
# prints $FX/result.json as structured output.

PR_ACT="$BATS_TEST_DIRNAME/pr-act"

setup() {
  TMP="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  export GIT_CONFIG_GLOBAL="$TMP/gitconfig-global"
  export GIT_CONFIG_SYSTEM=/dev/null
  printf '[user]\n\temail = t@example.com\n\tname = Tester\n[init]\n\tdefaultBranch = main\n' > "$GIT_CONFIG_GLOBAL"
  export PR_TEND_CONFIG="$TMP/global.json"
  export GH="$TMP/gh" FX="$TMP/fx"
  mkdir -p "$GH" "$FX" "$TMP/fakebin"
  cat > "$TMP/fakebin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH/calls"
echo '{"data":{"viewer":{"login":"me"},"repository":{"defaultBranchRef":{"name":"main"},"pullRequests":{"nodes":[]}}}}'
EOF
  cat > "$TMP/fakebin/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$FX/claude.args"
pwd > "$FX/claude.cwd"
args=("$@") prompt= i=0
while (( i < $# )); do
  case ${args[i]} in
    --allowedTools|--disallowedTools)
      i=$((i + 1)); while (( i < $# )) && [[ ${args[i]} != -* ]]; do i=$((i + 1)); done; continue ;;
    --session-id|--resume|--output-format|--json-schema|--permission-mode|--model|--effort) i=$((i + 2)); continue ;;
    -*) ;;
    *) prompt=${args[i]} ;;
  esac
  i=$((i + 1))
done
printf '%s' "$prompt" > "$FX/claude.prompt"
[[ -x $FX/agent ]] && "$FX/agent"
[[ -e $FX/fail ]] && { echo "claude: boom" >&2; exit 1; }
jq -n --argjson r "$(cat "$FX/result.json")" '{type: "result", is_error: false, structured_output: $r}'
EOF
  printf '#!/usr/bin/env bash\necho c >> file.txt\n' > "$FX/agent"
  chmod +x "$TMP/fakebin/gh" "$TMP/fakebin/claude" "$FX/agent"
  export PATH="$BATS_TEST_DIRNAME:$TMP/fakebin:$PATH"
  echo '{"outcome": "done", "commit_message": "Add c", "summary": "Added the third line."}' > "$FX/result.json"

  git init -q --bare "$TMP/origin.git"
  git clone -q "$TMP/origin.git" "$TMP/repo" 2>/dev/null
  cd "$TMP/repo"
  printf 'a\nb\n' > file.txt && git add file.txt && git commit -qm init && git push -q origin main 2>/dev/null
  git clone -q "$TMP/origin.git" "$TMP/other" 2>/dev/null
}

other_push() { # other_push <branch> <message>: a commit on origin that our clone hasn't fetched
  git -C "$TMP/other" switch -q "$1" 2>/dev/null || git -C "$TMP/other" switch -qc "$1"
  git -C "$TMP/other" commit -q --allow-empty -m "$2"
  git -C "$TMP/other" push -q origin "$1" 2>/dev/null
}
sha() { git rev-parse "$1"; }

# ── start: the worktree ──────────────────────────────────────────────────────

@test "start: no name is usage, nonzero" {
  run "$PR_ACT" start
  [ "$status" -ne 0 ]
  [[ "$output" == *"pr-act start"* ]]
  [ ! -e "$TMP/feat-x" ]
}

@test "start: a worktree beside this one, on a new branch of the same name; stdout is only its path" {
  run --separate-stderr "$PR_ACT" start --no-implement feat-x
  [ "$status" -eq 0 ]
  [ "$output" = "$TMP/feat-x" ]
  [ "$(git -C "$TMP/feat-x" branch --show-current)" = feat-x ]
}

@test "start: placed beside the current worktree's root, from a subdirectory too" {
  mkdir -p sub/deeper && cd sub/deeper
  run --separate-stderr "$PR_ACT" start --no-implement feat-x
  [ "$status" -eq 0 ]
  [ "$output" = "$TMP/feat-x" ]
}

@test "start: a new branch starts from the fetched origin default, not a stale local main" {
  other_push main "moved on"
  run --separate-stderr "$PR_ACT" start --no-implement feat-x
  [ "$status" -eq 0 ]
  [ "$(sha feat-x)" = "$(sha origin/main)" ]
  [ "$(sha feat-x)" != "$(sha main)" ]
}

@test "start: a new branch has no upstream until it's pushed" {
  "$PR_ACT" start --no-implement feat-x >/dev/null 2>&1
  run git config --get branch.feat-x.merge
  [ "$status" -ne 0 ]
}

@test "start: origin/HEAD names the default branch when it's set" {
  other_push trunk "trunk only"
  git fetch -q origin && git remote set-head origin trunk >/dev/null
  "$PR_ACT" start --no-implement feat-x >/dev/null 2>&1
  [ "$(sha feat-x)" = "$(sha origin/trunk)" ]
}

@test "start: an existing local branch gets the worktree, as it is" {
  git commit -q --allow-empty -m "local only" && git branch feat-x
  run --separate-stderr "$PR_ACT" start --no-implement feat-x
  [ "$status" -eq 0 ]
  [ "$(git -C "$TMP/feat-x" rev-parse HEAD)" = "$(sha main)" ]
  [ -z "$(git for-each-ref refs/pr-tend/feat-x/base)" ]
}

@test "start: a branch only on origin gets a local branch tracking it" {
  other_push feat-x "theirs"
  run --separate-stderr "$PR_ACT" start --no-implement feat-x
  [ "$status" -eq 0 ]
  [ "$(sha feat-x)" = "$(sha origin/feat-x)" ]
  [ "$(git config branch.feat-x.merge)" = refs/heads/feat-x ]
}

@test "start: refuses when the destination already exists, and creates no branch" {
  mkdir "$TMP/feat-x"
  run "$PR_ACT" start --no-implement feat-x
  [ "$status" -ne 0 ]
  [[ "$output" == *"$TMP/feat-x already exists"* ]]
  run git rev-parse -q --verify refs/heads/feat-x
  [ "$status" -ne 0 ]
}

@test "start: refuses a name git won't take as a branch" {
  run "$PR_ACT" start --no-implement "bad..name"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a valid branch name"* ]]
}

@test "start: git's chatter goes to stderr, never stdout" {
  run --separate-stderr "$PR_ACT" start --no-implement feat-x
  [ "$status" -eq 0 ]
  [ "$(wc -l <<<"$output" | tr -d ' ')" = 1 ]
}

# ── start: --parent ──────────────────────────────────────────────────────────

@test "start --parent: starts from the local parent, records pr-parent, pins base there" {
  git switch -qc A && git commit -q --allow-empty -m A && git switch -q main
  run --separate-stderr "$PR_ACT" start --no-implement --parent A feat-x
  [ "$status" -eq 0 ]
  [ "$(sha feat-x)" = "$(sha A)" ]
  [ "$(git config branch.feat-x.pr-parent)" = A ]
  [ "$(sha refs/pr-tend/feat-x/base)" = "$(sha A)" ]
}

@test "start --parent: a parent only on origin is used from there" {
  other_push A "A, theirs"
  run --separate-stderr "$PR_ACT" start --no-implement --parent A feat-x
  [ "$status" -eq 0 ]
  [ "$(sha feat-x)" = "$(sha origin/A)" ]
}

@test "start --parent: a parent that doesn't exist is refused before any worktree" {
  run "$PR_ACT" start --no-implement --parent nope feat-x
  [ "$status" -ne 0 ]
  [[ "$output" == *"no such parent branch: nope"* ]]
  [ ! -e "$TMP/feat-x" ]
}

# ── start: bookkeeping ───────────────────────────────────────────────────────

@test "start: records the task, pins base at the start point, enrolls the branch and the repo" {
  run --separate-stderr "$PR_ACT" start --no-implement feat-x "add a third line"
  [ "$status" -eq 0 ]
  [ "$(git config branch.feat-x.pr-task)" = "add a third line" ]
  [ "$(sha refs/pr-tend/feat-x/base)" = "$(sha origin/main)" ]
  [ "$(git config branch.feat-x.pr-tend)" = true ]
  [ "$(git config --global --get-all pr-tend.repo)" = "$TMP/repo" ]
}

@test "start: no session is minted until a step runs" {
  "$PR_ACT" start --no-implement feat-x "a task" >/dev/null 2>&1
  run git config --get branch.feat-x.pr-session
  [ "$status" -ne 0 ]
}

@test "start: without --no-implement the task is required" {
  run "$PR_ACT" start feat-x
  [ "$status" -ne 0 ]
  [[ "$output" == *"no task"* ]]
  [ ! -e "$TMP/feat-x" ]
}

# ── start: the setup hook (wt-new's two places) ──────────────────────────────

@test "start: runs \$GIT_COMMON_DIR/worktree-setup in the new worktree with WT_SRC, WT_DST, WT_BRANCH" {
  printf '#!/usr/bin/env bash\necho "$PWD|$WT_SRC|$WT_DST|$WT_BRANCH" > "%s/hook.out"\necho hook-stdout\n' "$TMP" > .git/worktree-setup
  chmod +x .git/worktree-setup
  run --separate-stderr "$PR_ACT" start --no-implement feat-x
  [ "$status" -eq 0 ]
  [ "$output" = "$TMP/feat-x" ]
  [ "$(cat "$TMP/hook.out")" = "$TMP/feat-x|$TMP/repo|$TMP/feat-x|feat-x" ]
  [[ "$stderr" == *hook-stdout* ]]
}

@test "start: a worktree-setup that isn't executable is skipped" {
  printf '#!/usr/bin/env bash\ntouch "%s/ran"\n' "$TMP" > .git/worktree-setup
  run --separate-stderr "$PR_ACT" start --no-implement feat-x
  [ "$status" -eq 0 ]
  [ ! -e "$TMP/ran" ]
}

@test "start: falls back to the wt.setup config command" {
  git config wt.setup 'echo "$WT_BRANCH" > "$WT_DST/../wt.out"'
  run --separate-stderr "$PR_ACT" start --no-implement feat-x
  [ "$status" -eq 0 ]
  [ "$(cat "$TMP/wt.out")" = feat-x ]
}

@test "start: the hook script wins over wt.setup" {
  printf '#!/usr/bin/env bash\ntouch "%s/script"\n' "$TMP" > .git/worktree-setup
  chmod +x .git/worktree-setup
  git config wt.setup "touch '$TMP/config'"
  "$PR_ACT" start --no-implement feat-x >/dev/null 2>&1
  [ -e "$TMP/script" ]
  [ ! -e "$TMP/config" ]
}

@test "start: a failing hook keeps the worktree, prints its path, exits nonzero, and doesn't implement" {
  printf '#!/usr/bin/env bash\necho broke >&2\nexit 3\n' > .git/worktree-setup
  chmod +x .git/worktree-setup
  run --separate-stderr "$PR_ACT" start feat-x "a task"
  [ "$status" -ne 0 ]
  [ "$output" = "$TMP/feat-x" ]
  [ -d "$TMP/feat-x" ]
  [[ "$stderr" == *broke* ]]
  [[ "$stderr" == *"pr-act implement feat-x"* ]]
  [ ! -e "$FX/claude.args" ]
}

@test "start: from a linked worktree, the new one goes beside it and the hook is still found" {
  printf '#!/usr/bin/env bash\necho "$WT_SRC" > "%s/src.out"\n' "$TMP" > .git/worktree-setup
  chmod +x .git/worktree-setup
  mkdir "$TMP/wts" && git worktree add -q -b one "$TMP/wts/one" 2>/dev/null
  cd "$TMP/wts/one"
  run --separate-stderr "$PR_ACT" start --no-implement feat-x
  [ "$status" -eq 0 ]
  [ "$output" = "$TMP/wts/feat-x" ]
  [ "$(cat "$TMP/src.out")" = "$TMP/wts/one" ]
}

# ── start, then implement ────────────────────────────────────────────────────

@test "start: runs implement in the new worktree; stdout is still only the path" {
  run --separate-stderr "$PR_ACT" start feat-x "add a third line"
  [ "$status" -eq 0 ]
  [ "$output" = "$TMP/feat-x" ]
  [ "$(cat "$FX/claude.cwd")" = "$TMP/feat-x" ]
  [ "$(git log -1 --format=%s feat-x)" = "Add c" ]
  [[ "$stderr" == *"Added the third line."* ]]
}

@test "start: a failed implement still prints the path, nonzero" {
  touch "$FX/fail"
  run --separate-stderr "$PR_ACT" start feat-x "a task"
  [ "$status" -ne 0 ]
  [ "$output" = "$TMP/feat-x" ]
  [ "$(git config branch.feat-x.pr-tend)" = true ]
}

# ── implement ────────────────────────────────────────────────────────────────

started() { # a worktree for feat-x with a task, no agent run yet
  "$PR_ACT" start --no-implement feat-x "${1:-add a third line}" >/dev/null 2>&1
  cd "$TMP/feat-x"
}

@test "implement: the agent edits, the pipeline commits with its message" {
  started
  run "$PR_ACT" implement
  [ "$status" -eq 0 ]
  [ "$(git log -1 --format=%s)" = "Add c" ]
  [ "$(tail -1 file.txt)" = c ]
  [ -z "$(git status --porcelain)" ]
  [[ "$output" == *"Added the third line."* ]]
  [[ "$output" == *"pr-act review"* ]]
}

@test "implement: the prompt carries the task and the verify command" {
  started "add a third line"
  echo '{"settings": {"verify": "echo checks-ok"}}' > "$PR_TEND_CONFIG"
  "$PR_ACT" implement >/dev/null
  grep -q 'add a third line' "$FX/claude.prompt"
  grep -q 'echo checks-ok' "$FX/claude.prompt"
}

@test "implement: mints the branch's session and stores it; a second run resumes it" {
  started
  "$PR_ACT" implement >/dev/null
  sid=$(git config branch.feat-x.pr-session)
  [ -n "$sid" ]
  [ "$(git config branch.feat-x.pr-harness)" = claude ]
  grep -qx -- --session-id "$FX/claude.args"
  "$PR_ACT" implement >/dev/null
  grep -qx -- --resume "$FX/claude.args"
  grep -qx -- "$sid" "$FX/claude.args"
}

allowed() { grep -A1 -x -- --allowedTools "$FX/claude.args" | tail -1; }

@test "implement: no free shell: no bare Bash, read-only git; commit, push and gh denied" {
  started
  "$PR_ACT" implement >/dev/null
  allow=$(allowed)
  deny=$(grep -A1 -x -- --disallowedTools "$FX/claude.args" | tail -1)
  [[ ",$allow," != *",Bash,"* ]]
  [[ $allow == *"Bash(git diff *)"* && $allow == *Edit* ]]
  [[ $deny == *"git commit"* && $deny == *"git push"* && $deny == *"gh "* ]]
}

@test "implement: a plain verify command becomes an exact rule" {
  started
  echo '{"settings": {"verify": "test -f file.txt"}}' > "$PR_TEND_CONFIG"
  "$PR_ACT" implement >/dev/null
  [[ ",$(allowed)," == *",Bash(test -f file.txt),"* ]]
}

@test "implement: a verify with shell syntax doesn't become a rule, and says where to allow it" {
  started
  echo '{"settings": {"verify": "ls *.txt"}}' > "$PR_TEND_CONFIG"
  run --separate-stderr "$PR_ACT" implement
  [ "$status" -eq 0 ]
  [[ $(allowed) != *"Bash(ls"* ]]
  [[ $stderr == *"settings.implementAllow"* ]]
}

@test "implement: settings.implementAllow adds its rules, and the prompt names them" {
  started
  echo '{"settings": {"implementAllow": ["Bash(bats *)", "WebFetch"]}}' > "$PR_TEND_CONFIG"
  "$PR_ACT" implement >/dev/null
  [[ ",$(allowed)," == *",Bash(bats *),WebFetch,"* ]]
  grep -qF 'Bash(bats *)' "$FX/claude.prompt"
}

@test "implement: pi gets no shell, and its prompt names no Claude rules" {
  started
  cat > "$TMP/fakebin/pi" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$FX/pi.args"
[[ -x $FX/agent ]] && "$FX/agent"
printf '```json\n%s\n```\n' "$(cat "$FX/result.json")"
EOF
  chmod +x "$TMP/fakebin/pi"
  echo '{"settings": {"verify": "test -f file.txt", "implementAllow": ["Bash(bats *)"]}}' > "$PR_TEND_CONFIG"
  run "$PR_ACT" implement --harness pi
  [ "$status" -eq 0 ]
  [ "$(grep -A1 -x -- --tools "$FX/pi.args" | tail -1)" = read,edit,write ]
  [[ $(<"$FX/pi.args") != *"Bash("* ]]
  grep -q "can't run commands" "$FX/pi.args"
}

@test "implement: with nothing allowed, the prompt says the agent can't run commands" {
  started
  "$PR_ACT" implement >/dev/null
  grep -q "can't run commands" "$FX/claude.prompt"
}

@test "implement: commits the agent made itself count as its work" {
  started
  printf '#!/usr/bin/env bash\necho c >> file.txt && git commit -qam "agent made it"\n' > "$FX/agent"
  run "$PR_ACT" implement
  [ "$status" -eq 0 ]
  [ "$(git log -1 --format=%s)" = "agent made it" ]
}

@test "implement: no commit message from the agent falls back to the task's first line" {
  started "$(printf 'add a third line\n\nmore detail')"
  echo '{"outcome": "done", "commit_message": null, "summary": "ok"}' > "$FX/result.json"
  "$PR_ACT" implement >/dev/null
  [ "$(git log -1 --format=%s)" = "add a third line" ]
}

@test "implement: done with nothing changed is a failure" {
  started
  rm "$FX/agent"
  run "$PR_ACT" implement
  [ "$status" -ne 0 ]
  [[ "$output" == *"changed nothing"* ]]
}

@test "implement: needs-input prints the question, leaves the edits uncommitted, nonzero" {
  started
  echo '{"outcome": "needs-input", "commit_message": null, "summary": "Which file?"}' > "$FX/result.json"
  run "$PR_ACT" implement
  [ "$status" -ne 0 ]
  [[ "$output" == *"Which file?"* ]]
  [ -n "$(git status --porcelain)" ]
  [ "$(git log -1 --format=%s)" = init ]
}

@test "implement: gave-up is nonzero with the agent's reason, nothing committed" {
  started
  echo '{"outcome": "gave-up", "commit_message": null, "summary": "makes no sense"}' > "$FX/result.json"
  run "$PR_ACT" implement
  [ "$status" -ne 0 ]
  [[ "$output" == *"makes no sense"* ]]
  [ "$(git log -1 --format=%s)" = init ]
}

@test "implement: verify runs after the commit; a failure is nonzero and keeps the commit" {
  started
  echo '{"settings": {"verify": "echo verify-ran; exit 1"}}' > "$PR_TEND_CONFIG"
  run "$PR_ACT" implement
  [ "$status" -ne 0 ]
  [[ "$output" == *verify-ran* ]]
  [ "$(git log -1 --format=%s)" = "Add c" ]
}

@test "implement: refuses a dirty worktree without calling the agent" {
  started
  echo dirt > dirt.txt
  run "$PR_ACT" implement
  [ "$status" -ne 0 ]
  [[ "$output" == *"uncommitted changes"* ]]
  [ ! -e "$FX/claude.args" ]
}

@test "implement: refuses with no task recorded" {
  "$PR_ACT" start --no-implement feat-x >/dev/null 2>&1
  cd "$TMP/feat-x"
  run "$PR_ACT" implement
  [ "$status" -ne 0 ]
  [[ "$output" == *"no task recorded"* ]]
}

@test "implement: the agent failing is nonzero and names the session" {
  started
  touch "$FX/fail"
  run "$PR_ACT" implement
  [ "$status" -ne 0 ]
  [[ "$output" == *"implement step failed"* ]]
}
