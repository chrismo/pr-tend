#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

# Test suite for `sd act attach` (A9, takeover): take branch.<b>.sd-lock, open
# the branch's session interactively in its worktree, release the lock when
# the session exits, however it exits. While the lock is held, agent steps
# refuse to run; a stale lock (its pid is gone from this host) is cleared.
#
# claude and pi are stubs standing in for the TUI: they record their args,
# cwd and the lock as it is while they run, then exit as $FX says
# ($FX/agent runs first, $FX/exit is the status, $FX/hang waits for a
# signal), and write the session's transcript where the real ones do
# ($CLAUDE_CONFIG_DIR, $PI_CODING_AGENT_SESSION_DIR), unless $FX/no-transcript. gh is a stub with
# no PRs, for the verbs that read sd state first.

SD_ACT="$BATS_TEST_DIRNAME/sd-act"

setup() {
  TMP="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  export GIT_CONFIG_GLOBAL="$TMP/gitconfig-global"
  export GIT_CONFIG_SYSTEM=/dev/null
  export SHEEPDOG_STATE_DIR="$TMP/state"   # harness_run logs usage there
  printf '[user]\n\temail = t@example.com\n\tname = Tester\n[init]\n\tdefaultBranch = main\n' > "$GIT_CONFIG_GLOBAL"
  export SHEEPDOG_CONFIG="$TMP/global.json"
  export GH="$TMP/gh" FX="$TMP/fx"
  mkdir -p "$GH" "$FX" "$TMP/fakebin"
  cat > "$TMP/fakebin/gh" <<'EOF'
#!/usr/bin/env bash
echo '{"data":{"viewer":{"login":"me"},"repository":{"defaultBranchRef":{"name":"main"},"pullRequests":{"nodes":[]}}}}'
EOF
  export CLAUDE_CONFIG_DIR="$TMP/claude" PI_CODING_AGENT_SESSION_DIR="$TMP/pi"
  mkdir -p "$CLAUDE_CONFIG_DIR/projects/-repo" "$PI_CODING_AGENT_SESSION_DIR/--repo--"
  for h in claude pi; do
    cat > "$TMP/fakebin/$h" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "\$FX/$h.args"
pwd > "\$FX/$h.cwd"
echo "\${ANTHROPIC_API_KEY-unset}" > "\$FX/$h.key"
sid=\$(grep -A1 -x -e --resume -e --session-id "\$FX/$h.args" | tail -1)
[[ -e \$FX/no-transcript ]] || { [[ $h == claude ]] && touch "\$CLAUDE_CONFIG_DIR/projects/-repo/\$sid.jsonl" || touch "\$PI_CODING_AGENT_SESSION_DIR/--repo--/2026-10-16T00-00-00-000Z_\$sid.jsonl"; }
git config --get branch.feat.sd-lock > "\$FX/$h.lock" || echo "(no lock)" > "\$FX/$h.lock"
echo \$\$ > "\$FX/$h.pid"
[[ -x \$FX/agent ]] && "\$FX/agent"
[[ -e \$FX/hang ]] && exec sleep 30
[[ -e \$FX/exit ]] && exit "\$(cat "\$FX/exit")"
exit 0
EOF
  done
  chmod +x "$TMP/fakebin/"*
  export PATH="$BATS_TEST_DIRNAME:$TMP/fakebin:$PATH"

  git init -q "$TMP/repo"
  cd "$TMP/repo"
  printf 'a\nb\n' > file.txt && git add file.txt && git commit -qm init
  git switch -qc feat
  printf 'a\nb\nc\n' > file.txt && git commit -qam "add c"
  git config branch.feat.sheepdog true
  git config branch.feat.sd-task "add a third line"
  git config branch.feat.sd-session 11111111-2222-4333-8444-555555555555
}

lock() { git config --get branch.feat.sd-lock; }
HOST=$(hostname)

# live_lock / dead_lock: a lock held by a process of this host that is running / gone.
live_lock() { sleep 30 & SLEEPER=$!; git config branch.feat.sd-lock "$SLEEPER@$HOST 2026-10-15T00:00:00Z"; }
dead_lock() { git config branch.feat.sd-lock "2147483646@$HOST 2026-10-15T00:00:00Z"; }

teardown() { [[ -z ${SLEEPER:-} ]] || kill "$SLEEPER" 2>/dev/null || true; }

# wait_for <file>: until the stub has written it (it is running).
wait_for() { local i; for ((i = 0; i < 100; i++)); do [[ -e $1 ]] && return 0; sleep 0.1; done; return 1; }

# ── attach ───────────────────────────────────────────────────────────────────

@test "attach: holds the lock while the session is open, in the branch's worktree, resuming its session" {
  run "$SD_ACT" attach
  [ "$status" -eq 0 ]
  [ "$(cat "$FX/claude.cwd")" = "$TMP/repo" ]
  grep -qx -- --resume "$FX/claude.args"
  grep -qx -- 11111111-2222-4333-8444-555555555555 "$FX/claude.args"
  ! grep -q -- '^-p$' "$FX/claude.args" || false
  [[ "$(cat "$FX/claude.lock")" =~ ^[0-9]+@$HOST\ 20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]T ]]
  run lock
  [ "$status" -ne 0 ]
}

@test "attach: says what it attached to, on stderr" {
  run --separate-stderr "$SD_ACT" attach
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"attached to feat"* ]]
  [[ "$stderr" == *"11111111-2222-4333-8444-555555555555"* ]]
  [ -z "$output" ]
}

@test "attach: a named branch, from another worktree" {
  git worktree add -q "$TMP/wt-main" main
  cd "$TMP/wt-main"
  run "$SD_ACT" attach feat
  [ "$status" -eq 0 ]
  [ "$(cat "$FX/claude.cwd")" = "$TMP/repo" ]
}

@test "attach: a branch checked out nowhere fails" {
  git switch -q main
  git worktree prune
  run "$SD_ACT" attach feat
  [ "$status" -ne 0 ]
  [[ "$output" == *"isn't checked out"* ]]
  [ ! -e "$FX/claude.args" ]
}

@test "attach: no session yet: starts one with --session-id and remembers it" {
  git config --unset branch.feat.sd-session
  run "$SD_ACT" attach
  [ "$status" -eq 0 ]
  grep -qx -- --session-id "$FX/claude.args"
  sid=$(grep -A1 -x -- --session-id "$FX/claude.args" | tail -1)
  [[ $sid =~ ^[0-9a-f-]{36}$ ]]
  [ "$(git config branch.feat.sd-session)" = "$sid" ]
  [ "$(git config branch.feat.sd-harness)" = claude ]
}

@test "attach: no session yet, and the harness wrote no transcript: nothing stored, and it says so" {
  git config --unset branch.feat.sd-session
  touch "$FX/no-transcript"
  run --separate-stderr "$SD_ACT" attach
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"no transcript"* ]]
  run git config --get branch.feat.sd-session
  [ "$status" -ne 0 ]
  run lock
  [ "$status" -ne 0 ]
}

@test "attach: a resumed session stays stored even when the harness wrote nothing" {
  touch "$FX/no-transcript"
  run "$SD_ACT" attach
  [ "$status" -eq 0 ]
  [ "$(git config branch.feat.sd-session)" = 11111111-2222-4333-8444-555555555555 ]
}

@test "attach: the harness block's model, effort and args become the TUI's flags" {
  echo '{"harnesses": {"claude": {"model": "opus", "effort": "high", "args": "--verbose --fast"}}}' > "$SHEEPDOG_CONFIG"
  run "$SD_ACT" attach
  [ "$status" -eq 0 ]
  [ "$(tr '\n' ' ' < "$FX/claude.args")" = "--resume 11111111-2222-4333-8444-555555555555 --model opus --effort high --verbose --fast " ]
}

@test "attach: claude runs without ANTHROPIC_API_KEY unless harnesses.claude.useApiKey" {
  export ANTHROPIC_API_KEY=sk-no-credit
  run "$SD_ACT" attach
  [ "$status" -eq 0 ]
  [ "$(cat "$FX/claude.key")" = unset ]
  echo '{"harnesses": {"claude": {"useApiKey": true}}}' > "$SHEEPDOG_CONFIG"
  run "$SD_ACT" attach
  [ "$status" -eq 0 ]
  [ "$(cat "$FX/claude.key")" = sk-no-credit ]
}

@test "attach: pi keeps ANTHROPIC_API_KEY" {
  export ANTHROPIC_API_KEY=sk-paid
  git config branch.feat.sd-harness pi
  run "$SD_ACT" attach
  [ "$status" -eq 0 ]
  [ "$(cat "$FX/pi.key")" = sk-paid ]
}

@test "attach: pi's flags: provider, model, thinking" {
  echo '{"harnesses": {"pi": {"provider": "cf", "model": "haiku", "effort": "low"}}}' > "$SHEEPDOG_CONFIG"
  git config branch.feat.sd-harness pi
  run "$SD_ACT" attach
  [ "$status" -eq 0 ]
  [ "$(tr '\n' ' ' < "$FX/pi.args")" = "--session-id 11111111-2222-4333-8444-555555555555 --provider cf --model haiku --thinking low " ]
}

@test "attach: pi: pi --session-id, no -p" {
  git config branch.feat.sd-harness pi
  run "$SD_ACT" attach
  [ "$status" -eq 0 ]
  [ ! -e "$FX/claude.args" ]
  grep -qx -- --session-id "$FX/pi.args"
  grep -qx -- 11111111-2222-4333-8444-555555555555 "$FX/pi.args"
  ! grep -q -- '^-p$' "$FX/pi.args" || false
  [[ "$(cat "$FX/pi.lock")" =~ ^[0-9]+@ ]]
}

@test "attach: --harness picks the harness for a branch with no session" {
  git config --unset branch.feat.sd-session
  run "$SD_ACT" attach --harness pi
  [ "$status" -eq 0 ]
  [ ! -e "$FX/claude.args" ]
  grep -qx -- --session-id "$FX/pi.args"
  [ "$(git config branch.feat.sd-harness)" = pi ]
}

@test "attach: --harness can't switch a branch whose session belongs to the other harness" {
  run "$SD_ACT" attach --harness pi
  [ "$status" -ne 0 ]
  [[ "$output" == *"belongs to claude"* ]]
  [ ! -e "$FX/pi.args" ]
  run lock
  [ "$status" -ne 0 ]
}

@test "attach: the session's exit status comes through, and the lock is released anyway" {
  echo 3 > "$FX/exit"
  run "$SD_ACT" attach
  [ "$status" -eq 3 ]
  run lock
  [ "$status" -ne 0 ]
}

@test "attach: Ctrl-C (SIGINT to the foreground group) releases the lock" {
  touch "$FX/hang"
  "$SD_ACT" attach 2>/dev/null &
  pid=$!
  wait_for "$FX/claude.pid"
  [[ "$(lock)" =~ ^[0-9]+@ ]]
  kill -INT "$pid" "$(cat "$FX/claude.pid")"
  wait "$pid" || true
  run lock
  [ "$status" -ne 0 ]
}

@test "attach: a new session is still recorded when the TUI was interrupted" {
  git config --unset branch.feat.sd-session
  touch "$FX/hang"
  "$SD_ACT" attach 2>/dev/null &
  pid=$!
  wait_for "$FX/claude.pid"
  touch "$CLAUDE_CONFIG_DIR/projects/-repo/$(grep -A1 -x -- --session-id "$FX/claude.args" | tail -1).jsonl"
  kill -INT "$pid" "$(cat "$FX/claude.pid")"
  wait "$pid" || true
  [[ "$(git config branch.feat.sd-session)" =~ ^[0-9a-f-]{36}$ ]]
  run lock
  [ "$status" -ne 0 ]
}

@test "attach: SIGTERM releases the lock" {
  touch "$FX/hang"
  "$SD_ACT" attach 2>/dev/null &
  pid=$!
  wait_for "$FX/claude.pid"
  kill -TERM "$pid" "$(cat "$FX/claude.pid")"
  wait "$pid" || true
  run lock
  [ "$status" -ne 0 ]
}

@test "attach: refuses while a live lock is held; --force takes it over" {
  live_lock
  run "$SD_ACT" attach
  [ "$status" -ne 0 ]
  [[ "$output" == *"already attached"* ]]
  [[ "$output" == *"$SLEEPER@$HOST"* ]]
  [[ "$output" == *"--force"* ]]
  [ ! -e "$FX/claude.args" ]
  [ "$(lock)" = "$SLEEPER@$HOST 2026-10-15T00:00:00Z" ]

  run "$SD_ACT" attach --force
  [ "$status" -eq 0 ]
  [[ "$(cat "$FX/claude.lock")" =~ ^[0-9]+@ ]]
  [ "$(cat "$FX/claude.lock")" != "$SLEEPER@$HOST 2026-10-15T00:00:00Z" ]
  run lock
  [ "$status" -ne 0 ]
}

@test "attach: a stale lock (its process is gone) is replaced, with a note" {
  dead_lock
  run --separate-stderr "$SD_ACT" attach
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"stale lock"* ]]
  [[ "$(cat "$FX/claude.lock")" =~ ^[0-9]+@ ]]
  run lock
  [ "$status" -ne 0 ]
}

@test "attach: a lock from another host is never stale" {
  git config branch.feat.sd-lock "1@elsewhere.example 2026-10-15T00:00:00Z"
  run "$SD_ACT" attach
  [ "$status" -ne 0 ]
  [[ "$output" == *"already attached"* ]]
  [ ! -e "$FX/claude.args" ]
}

@test "attach: releases only its own lock, not one that replaced it" {
  cat > "$FX/agent" <<'EOF'
#!/usr/bin/env bash
git config branch.feat.sd-lock "other@elsewhere.example 2026-10-15T00:00:00Z"
EOF
  chmod +x "$FX/agent"
  run "$SD_ACT" attach
  [ "$status" -eq 0 ]
  [ "$(lock)" = "other@elsewhere.example 2026-10-15T00:00:00Z" ]
}

@test "--help lists attach" {
  run "$SD_ACT" --help
  [[ "$output" =~ sd\ act\ attach\  ]]
}

# ── agent steps while attached ───────────────────────────────────────────────

@test "implement: refused while attached; nothing runs" {
  live_lock
  run "$SD_ACT" implement
  [ "$status" -ne 0 ]
  [[ "$output" == *"attached"* ]]
  [[ "$output" == *"$SLEEPER@$HOST"* ]]
  [ ! -e "$FX/claude.args" ]
}

@test "describe: refused while attached" {
  live_lock
  run "$SD_ACT" describe
  [ "$status" -ne 0 ]
  [[ "$output" == *"attached"* ]]
  [ ! -e "$FX/claude.args" ]
}

@test "review: refused while attached, before verify runs" {
  live_lock
  echo '{"settings": {"verify": "touch verify-ran"}}' > "$SHEEPDOG_CONFIG"
  run "$SD_ACT" review
  [ "$status" -ne 0 ]
  [[ "$output" == *"attached"* ]]
  [ ! -e verify-ran ]
}

@test "verify is mechanical: it runs while attached" {
  live_lock
  echo '{"settings": {"verify": "true"}}' > "$SHEEPDOG_CONFIG"
  run "$SD_ACT" verify
  [ "$status" -eq 0 ]
}

@test "every verb clears a stale lock first" {
  dead_lock
  run --separate-stderr "$SD_ACT" enroll
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"stale lock"* ]]
  run lock
  [ "$status" -ne 0 ]
}

@test "a stale lock is cleared and the step runs" {
  dead_lock
  echo '{"outcome": "done", "summary": "did it", "commit_message": "add c"}' > "$FX/result.json"
  cat > "$TMP/fakebin/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$FX/claude.args"
echo d >> file.txt
jq -n --argjson r "$(cat "$FX/result.json")" '{type: "result", is_error: false, structured_output: $r}'
EOF
  run --separate-stderr "$SD_ACT" implement
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"stale lock"* ]]
  [ -e "$FX/claude.args" ]
  run lock
  [ "$status" -ne 0 ]
  # The step's usage record names the step and the branch.
  [[ "$(cat "$SHEEPDOG_STATE_DIR/usage.sup")" == *'branch:"feat",step:"implement",harness:"claude"'* ]]
}

@test "--force runs an agent step over a live lock" {
  live_lock
  echo '{"outcome": "done", "summary": "did it", "commit_message": "add c"}' > "$FX/result.json"
  cat > "$TMP/fakebin/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$FX/claude.args"
echo d >> file.txt
jq -n --argjson r "$(cat "$FX/result.json")" '{type: "result", is_error: false, structured_output: $r}'
EOF
  run "$SD_ACT" implement --force
  [ "$status" -eq 0 ]
  [ -e "$FX/claude.args" ]
  [ "$(lock)" = "$SLEEPER@$HOST 2026-10-15T00:00:00Z" ]
}
