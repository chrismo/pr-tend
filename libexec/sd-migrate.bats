#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

# Test suite for libexec/sd-migrate: pr-tend's state moved to sheepdog's names.

SD_MIGRATE="$BATS_TEST_DIRNAME/sd-migrate"

setup() {
  TMP="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  export HOME="$TMP/home"
  mkdir -p "$HOME"
  unset XDG_CONFIG_HOME
  export SHEEPDOG_WATCH_LAUNCH_AGENTS="$TMP/LaunchAgents"
  export GIT_CONFIG_GLOBAL="$TMP/gitconfig-global"
  export GIT_CONFIG_SYSTEM=/dev/null
  printf '[user]\n\temail = t@example.com\n\tname = Tester\n[init]\n\tdefaultBranch = main\n' > "$GIT_CONFIG_GLOBAL"
  git init -q "$TMP/repo"
  cd "$TMP/repo"
  git commit -q --allow-empty -m init
  git switch -qc feat
  git commit -q --allow-empty -m feat
  cd "$TMP"
}

# old_repo <path> — registered the way pr-tend registered it.
old_repo() { git config --global --add pr-tend.repo "$1"; }

@test "runs under bash 5 via the bash5 shebang" {
  run head -1 "$SD_MIGRATE"
  [ "$output" = "#!/usr/bin/env bash5" ]
}

@test "--help: usage on stdout" {
  run "$SD_MIGRATE" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage"* ]]
}

@test "an unknown option fails" {
  run "$SD_MIGRATE" --frobnicate
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown option"* ]]
}

@test "nothing to migrate: says so" {
  run "$SD_MIGRATE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to migrate"* ]]
}

# ── git config ───────────────────────────────────────────────────────────────

@test "global: pr-tend.repo values become sheepdog.repo" {
  old_repo "$TMP/repo"
  mkdir "$TMP/other" && git init -q "$TMP/other"
  old_repo "$TMP/other"
  run "$SD_MIGRATE"
  [ "$status" -eq 0 ]
  [ "$(git config --global --get-all sheepdog.repo)" = "$TMP/repo"$'\n'"$TMP/other" ]
  [ -z "$(git config --global --get-regexp '^pr-tend\.' || true)" ]
}

@test "global: a value already under the new name is not added twice" {
  old_repo "$TMP/repo"
  git config --global --add sheepdog.repo "$TMP/repo"
  run "$SD_MIGRATE"
  [ "$status" -eq 0 ]
  [ "$(git config --global --get-all sheepdog.repo)" = "$TMP/repo" ]
}

@test "global: a registered repo that no longer exists is moved, with a warning" {
  old_repo "$TMP/gone"
  run "$SD_MIGRATE"
  [ "$status" -eq 0 ]
  [ "$(git config --global --get-all sheepdog.repo)" = "$TMP/gone" ]
  [[ "$output" == *"warning"*"$TMP/gone"* ]]
}

@test "branch: every pr-tend key moves to its new name" {
  old_repo "$TMP/repo"
  cd "$TMP/repo"
  git config branch.feat.pr-tend true
  git config branch.feat.pr-task "two
lines"
  git config branch.feat.pr-parent main
  git config branch.feat.pr-session abc-123
  git config branch.feat.pr-harness claude
  git config branch.feat.pr-lock true
  git config branch.feat.pr-scope apps/web
  git config --add branch.feat.pr-handled 1
  git config --add branch.feat.pr-handled 2
  run "$SD_MIGRATE"
  [ "$status" -eq 0 ]
  [ "$(git config branch.feat.sheepdog)" = true ]
  [ "$(git config branch.feat.sd-task)" = "two
lines" ]
  [ "$(git config branch.feat.sd-parent)" = main ]
  [ "$(git config branch.feat.sd-session)" = abc-123 ]
  [ "$(git config branch.feat.sd-harness)" = claude ]
  [ "$(git config branch.feat.sd-lock)" = true ]
  [ "$(git config branch.feat.sd-scope)" = apps/web ]
  [ "$(git config --get-all branch.feat.sd-handled)" = $'1\n2' ]
  [ -z "$(git config --get-regexp '\.pr-' || true)" ]
}

@test "branch: a different value already under the new name is a conflict: both kept, nonzero" {
  old_repo "$TMP/repo"
  cd "$TMP/repo"
  git config branch.feat.pr-parent dev
  git config branch.feat.sd-parent main
  git config branch.feat.pr-session same
  git config branch.feat.sd-session same
  run "$SD_MIGRATE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"conflict"*"branch.feat.sd-parent"* ]] || false
  [ "$(git config --get-all branch.feat.sd-parent)" = main ]
  [ "$(git config branch.feat.pr-parent)" = dev ]
  [ "$(git config --get-all branch.feat.sd-session)" = same ]
  [ -z "$(git config branch.feat.pr-session || true)" ]
}

@test "branch: handled ids merge with ones already under the new name" {
  old_repo "$TMP/repo"
  cd "$TMP/repo"
  git config --add branch.feat.pr-handled 1
  git config --add branch.feat.pr-handled 2
  git config --add branch.feat.sd-handled 2
  git config --add branch.feat.sd-handled 3
  run "$SD_MIGRATE"
  [ "$status" -eq 0 ]
  [ "$(git config --get-all branch.feat.sd-handled | sort)" = $'1\n2\n3' ]
}

@test "branch: a key set with no value means true" {
  old_repo "$TMP/repo"
  printf '[branch "feat"]\n\tpr-tend\n' >> "$TMP/repo/.git/config"
  run "$SD_MIGRATE"
  [ "$status" -eq 0 ]
  [ "$(git -C "$TMP/repo" config --type=bool branch.feat.sheepdog)" = true ]
}

@test "branch: a name with a slash and a dot" {
  old_repo "$TMP/repo"
  cd "$TMP/repo"
  git config branch.topic/v1.2.pr-tend true
  git config branch.topic/v1.2.pr-parent feat
  run "$SD_MIGRATE"
  [ "$status" -eq 0 ]
  [ "$(git config branch.topic/v1.2.sheepdog)" = true ]
  [ "$(git config branch.topic/v1.2.sd-parent)" = feat ]
}

@test "branch: keys that aren't pr-tend's are left alone" {
  old_repo "$TMP/repo"
  cd "$TMP/repo"
  git config branch.feat.pr-tend true
  git config branch.feat.remote origin
  git config branch.feat.pr-other keep
  run "$SD_MIGRATE"
  [ "$(git config branch.feat.remote)" = origin ]
  [ "$(git config branch.feat.pr-other)" = keep ]
}

@test "repo: local pr-tend.* keys move" {
  old_repo "$TMP/repo"
  git -C "$TMP/repo" config pr-tend.verify make
  run "$SD_MIGRATE"
  [ "$status" -eq 0 ]
  [ "$(git -C "$TMP/repo" config sheepdog.verify)" = make ]
  [ -z "$(git -C "$TMP/repo" config pr-tend.verify || true)" ]
}

@test "repo: the current repo is migrated even when not registered" {
  cd "$TMP/repo"
  git config branch.feat.pr-parent main
  run "$SD_MIGRATE"
  [ "$status" -eq 0 ]
  [ "$(git config branch.feat.sd-parent)" = main ]
}

# ── refs ─────────────────────────────────────────────────────────────────────

@test "refs: pins move to refs/sheepdog with their SHAs" {
  old_repo "$TMP/repo"
  cd "$TMP/repo"
  local a b
  a=$(git rev-parse main) b=$(git rev-parse feat)
  git update-ref refs/pr-tend/feat/base "$a"
  git update-ref refs/pr-tend/feat/local "$b"
  git update-ref refs/pr-tend/topic/sub/local-base "$a"
  run "$SD_MIGRATE"
  [ "$status" -eq 0 ]
  [ "$(git rev-parse refs/sheepdog/feat/base)" = "$a" ]
  [ "$(git rev-parse refs/sheepdog/feat/local)" = "$b" ]
  [ "$(git rev-parse refs/sheepdog/topic/sub/local-base)" = "$a" ]
  [ -z "$(git for-each-ref refs/pr-tend/)" ]
}

@test "refs: a new ref already at the same SHA: the old one is dropped" {
  old_repo "$TMP/repo"
  cd "$TMP/repo"
  git update-ref refs/pr-tend/feat/base main
  git update-ref refs/sheepdog/feat/base main
  run "$SD_MIGRATE"
  [ "$status" -eq 0 ]
  [ -z "$(git for-each-ref refs/pr-tend/)" ]
}

@test "refs: a new ref at a different SHA is a conflict: both kept, nonzero" {
  old_repo "$TMP/repo"
  cd "$TMP/repo"
  git update-ref refs/pr-tend/feat/base main
  git update-ref refs/sheepdog/feat/base feat
  git update-ref refs/pr-tend/feat/local feat
  run "$SD_MIGRATE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"refs/sheepdog/feat/base"* ]] || false
  [ "$(git rev-parse refs/pr-tend/feat/base)" = "$(git rev-parse main)" ]
  [ "$(git rev-parse refs/sheepdog/feat/base)" = "$(git rev-parse feat)" ]
  [ "$(git rev-parse refs/sheepdog/feat/local)" = "$(git rev-parse feat)" ]
}

# ── files ────────────────────────────────────────────────────────────────────

@test "git dir: pr-tend/ moves to sheepdog/" {
  old_repo "$TMP/repo"
  mkdir -p "$TMP/repo/.git/pr-tend"
  echo '{}' > "$TMP/repo/.git/pr-tend/feat.json"
  echo '{}' > "$TMP/repo/.git/pr-tend/topic%2Fsub.json"
  run "$SD_MIGRATE"
  [ "$status" -eq 0 ]
  [ -f "$TMP/repo/.git/sheepdog/feat.json" ]
  [ -f "$TMP/repo/.git/sheepdog/topic%2Fsub.json" ]
  [ ! -e "$TMP/repo/.git/pr-tend" ]
}

@test "git dir: from a linked worktree, the main repo's git dir" {
  git -C "$TMP/repo" worktree add -q "$TMP/wt" main 2>/dev/null
  mkdir -p "$TMP/repo/.git/pr-tend"
  echo '{}' > "$TMP/repo/.git/pr-tend/feat.json"
  cd "$TMP/wt"
  run "$SD_MIGRATE"
  [ "$status" -eq 0 ]
  [ -f "$TMP/repo/.git/sheepdog/feat.json" ]
}

@test "git dir: a file already at the new path is a conflict: both kept, nonzero" {
  old_repo "$TMP/repo"
  mkdir -p "$TMP/repo/.git/pr-tend" "$TMP/repo/.git/sheepdog"
  echo old > "$TMP/repo/.git/pr-tend/feat.json"
  echo new > "$TMP/repo/.git/sheepdog/feat.json"
  echo moved > "$TMP/repo/.git/pr-tend/other.json"
  run "$SD_MIGRATE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"feat.json"* ]] || false
  [ "$(cat "$TMP/repo/.git/pr-tend/feat.json")" = old ]
  [ "$(cat "$TMP/repo/.git/sheepdog/feat.json")" = new ]
  [ "$(cat "$TMP/repo/.git/sheepdog/other.json")" = moved ]
}

@test "home: ~/.config/pr-tend and ~/.local/state/pr-tend move" {
  mkdir -p "$HOME/.config/pr-tend" "$HOME/.local/state/pr-tend"
  echo '{"harness":"pi"}' > "$HOME/.config/pr-tend/config.json"
  echo 'last pass' > "$HOME/.local/state/pr-tend/last-pass"
  run "$SD_MIGRATE"
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/.config/sheepdog/config.json")" = '{"harness":"pi"}' ]
  [ "$(cat "$HOME/.local/state/sheepdog/last-pass")" = 'last pass' ]
  [ ! -e "$HOME/.config/pr-tend" ]
  [ ! -e "$HOME/.local/state/pr-tend" ]
}

@test "home: a symlinked config dir moves as the link" {
  mkdir -p "$TMP/dotfiles/pr-tend" "$HOME/.config"
  echo '{}' > "$TMP/dotfiles/pr-tend/config.json"
  ln -s "$TMP/dotfiles/pr-tend" "$HOME/.config/pr-tend"
  run "$SD_MIGRATE"
  [ "$status" -eq 0 ]
  [ -L "$HOME/.config/sheepdog" ]
  [ "$(readlink "$HOME/.config/sheepdog")" = "$TMP/dotfiles/pr-tend" ]
  [ ! -e "$HOME/.config/pr-tend" ]
  [ -f "$TMP/dotfiles/pr-tend/config.json" ]
}

@test "home: a symlinked old dir with the new one already there is a conflict" {
  mkdir -p "$TMP/dotfiles/pr-tend" "$HOME/.config/sheepdog"
  ln -s "$TMP/dotfiles/pr-tend" "$HOME/.config/pr-tend"
  run "$SD_MIGRATE"
  [ "$status" -ne 0 ]
  [ -L "$HOME/.config/pr-tend" ]
}

@test "home: XDG_CONFIG_HOME locates the config dir" {
  export XDG_CONFIG_HOME="$TMP/xdg"
  mkdir -p "$XDG_CONFIG_HOME/pr-tend"
  echo '{}' > "$XDG_CONFIG_HOME/pr-tend/config.json"
  run "$SD_MIGRATE"
  [ "$status" -eq 0 ]
  [ -f "$XDG_CONFIG_HOME/sheepdog/config.json" ]
}

# ── dry run, repeat ──────────────────────────────────────────────────────────

# everything — one of each kind of state.
everything() {
  old_repo "$TMP/repo"
  git -C "$TMP/repo" config branch.feat.pr-tend true
  git -C "$TMP/repo" update-ref refs/pr-tend/feat/base main
  mkdir -p "$TMP/repo/.git/pr-tend" "$HOME/.config/pr-tend"
  echo '{}' > "$TMP/repo/.git/pr-tend/feat.json"
  echo '{}' > "$HOME/.config/pr-tend/config.json"
}

# snapshot — every bit of state, old and new names.
snapshot() {
  git config --global --list
  git -C "$TMP/repo" config --list --local
  git -C "$TMP/repo" for-each-ref
  find "$TMP/repo/.git/pr-tend" "$TMP/repo/.git/sheepdog" "$HOME" 2>/dev/null | sort
}

@test "--dry-run: says what it would move and changes nothing" {
  everything
  local before; before=$(snapshot)
  run "$SD_MIGRATE" --dry-run
  [ "$status" -eq 0 ]
  [ "$(snapshot)" = "$before" ]
  [[ "$output" == *"would move"*"pr-tend.repo"* ]] || false
  [[ "$output" == *"would move"*"branch.feat.pr-tend"* ]] || false
  [[ "$output" == *"would move"*"refs/pr-tend/feat/base"* ]] || false
  [[ "$output" == *"would move"*"feat.json"* ]] || false
  [[ "$output" == *"would move"*"config.json"* ]]
}

@test "a second run finds nothing to migrate" {
  everything
  "$SD_MIGRATE"
  run "$SD_MIGRATE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to migrate"* ]]
}

# ── warnings ─────────────────────────────────────────────────────────────────

@test "warns about old env vars in shell startup files" {
  echo 'export PR_TEND_CONFIG=~/x.json' > "$HOME/.zshrc"
  echo 'export PR_WATCH_TIMEOUT=60' > "$HOME/.bashrc"
  run "$SD_MIGRATE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"warning"*".zshrc"*"PR_TEND_CONFIG"* ]] || false
  [[ "$output" == *"warning"*".bashrc"*"PR_WATCH_TIMEOUT"* ]] || false
  [ "$(cat "$HOME/.zshrc")" = 'export PR_TEND_CONFIG=~/x.json' ]
}

@test "warns about old env vars set now" {
  PR_TEND_STATE_DIR=/x run "$SD_MIGRATE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"warning"*"PR_TEND_STATE_DIR"* ]]
}

@test "warns about the old watcher job" {
  mkdir -p "$SHEEPDOG_WATCH_LAUNCH_AGENTS"
  echo old > "$SHEEPDOG_WATCH_LAUNCH_AGENTS/com.pr-tend.pr-watch.plist"
  run "$SD_MIGRATE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"warning"*"com.pr-tend.pr-watch"*"sd watch install"* ]]
}

@test "warns about a local reviewer set in a branch file, after moving it" {
  old_repo "$TMP/repo"
  mkdir -p "$TMP/repo/.git/pr-tend"
  echo '{"settings":{"localReview":"x"}}' > "$TMP/repo/.git/pr-tend/feat.json"
  run "$SD_MIGRATE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"warning"*"sheepdog/feat.json"*"localReview"* ]]
}

@test "warns that a configured local reviewer reads SHEEPDOG_* now" {
  mkdir -p "$HOME/.config/pr-tend"
  echo '{"settings":{"localReview":"~/bin/my-review"}}' > "$HOME/.config/pr-tend/config.json"
  run "$SD_MIGRATE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"warning"*"localReview"*"SHEEPDOG_BASE"* ]]
}
