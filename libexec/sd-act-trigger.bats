#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

# Test suite for `sd act trigger` (A5): post settings.botCommand as a PR
# comment and pin bot at HEAD with its base; skip when already pinned there.
# The bot reviews what is on GitHub, so an unpushed HEAD is refused, and a
# local review that doesn't cover HEAD is a soft refusal (--force).
#
# Real git and the real sd state. gh is a stub: graphql answers from
# $GH/<branch>.json, the PR id lookup and addComment are logged to $GH/calls.

SD_ACT="$BATS_TEST_DIRNAME/sd-act"
SD_CONFIG="$BATS_TEST_DIRNAME/sd-config"

setup() {
  TMP="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  export GIT_CONFIG_GLOBAL="$TMP/gitconfig-global"
  export GIT_CONFIG_SYSTEM=/dev/null
  printf '[user]\n\temail = t@example.com\n\tname = Tester\n[init]\n\tdefaultBranch = main\n' > "$GIT_CONFIG_GLOBAL"
  export SHEEPDOG_CONFIG="$TMP/global.json"
  export GH="$TMP/gh"
  mkdir -p "$GH" "$TMP/fakebin"
  cat > "$TMP/fakebin/gh" <<'EOF'
#!/usr/bin/env bash
q="" b="" fields=()
for a; do
  [[ $a == branch=* ]] && b=${a#branch=}
  [[ $a == query=* ]] && q=${a#query=}
  [[ $a == body=* || $a == subject=* || $a == url=* ]] && fields+=("$a")
done
case $q in
  *addComment*) printf 'addComment %s\n' "${fields[*]}" >> "$GH/calls"
    [[ -e $GH/fail-comment ]] && { echo "gh: boom" >&2; exit 1; }
    echo '{"data":{"addComment":{"clientMutationId":null}}}' ;;
  *resource\(url*) printf 'resource %s\n' "${fields[*]}" >> "$GH/calls"; echo '{"data":{"resource":{"id":"PR_node7"}}}' ;;
  *) if [[ -f $GH/$b.json ]]; then cat "$GH/$b.json"
     else echo '{"data":{"viewer":{"login":"me"},"repository":{"defaultBranchRef":{"name":"main"},"pullRequests":{"nodes":[]}}}}'
     fi ;;
esac
EOF
  chmod +x "$TMP/fakebin/gh"
  export PATH="$BATS_TEST_DIRNAME:$TMP/fakebin:$PATH"
  "$SD_CONFIG" set --global settings.botCommand "/review-bot"

  git init -q --bare "$TMP/origin.git"
  git clone -q "$TMP/origin.git" "$TMP/repo" 2>/dev/null
  cd "$TMP/repo"
  printf 'a\nb\n' > file.txt && git add file.txt && git commit -qm init && git push -q origin main 2>/dev/null
  git switch -qc feat
  printf 'a\nb\nc\n' > file.txt && git commit -qam "add c"
  git push -q -u origin feat 2>/dev/null
  open_pr feat 7
  git update-ref refs/sheepdog/feat/local HEAD
  git update-ref refs/sheepdog/feat/local-base main
}

open_pr() { # open_pr <branch> <number> [state]
  jq -n --arg b "$1" --argjson n "$2" --arg st "${3:-OPEN}" --arg h "$(git rev-parse "$1")" '{data: {viewer: {login: "me"},
    repository: {defaultBranchRef: {name: "main"},
      pullRequests: {nodes: [{number: $n, url: "https://example/pr/7", state: $st, isDraft: true, baseRefName: "main",
                              headRefName: $b, headRefOid: $h, isCrossRepository: false}]}}}}' > "$GH/$1.json"
}
calls() { cat "$GH/calls" 2>/dev/null; }
pin() { git rev-parse -q --verify "refs/sheepdog/feat/$1" || true; }

@test "trigger: posts the bot command on the PR and pins bot at HEAD with its base" {
  run "$SD_ACT" trigger
  [ "$status" -eq 0 ]
  [[ "$(calls)" == *"addComment subject=PR_node7 body=/review-bot"* ]]
  [ "$(pin bot)" = "$(git rev-parse HEAD)" ]
  [ "$(pin bot-base)" = "$(git rev-parse origin/main)" ]
  [[ "$output" == *"triggered"* ]]
}

@test "trigger: already pinned at HEAD: nothing posted" {
  git update-ref refs/sheepdog/feat/bot HEAD
  run "$SD_ACT" trigger
  [ "$status" -eq 0 ]
  [[ "$output" == *"already"* ]]
  [ -z "$(calls)" ]
}

@test "trigger: HEAD not on the remote yet is refused" {
  echo d >> file.txt && git commit -qam "add d"
  git update-ref refs/sheepdog/feat/local HEAD
  run "$SD_ACT" trigger
  [ "$status" -ne 0 ]
  [[ "$output" == *"push"* ]]
  [ -z "$(calls)" ]
  [ -z "$(pin bot)" ]
}

@test "trigger: no PR is refused" {
  rm "$GH/feat.json"
  run "$SD_ACT" trigger
  [ "$status" -ne 0 ]
  [[ "$output" == *"no PR"* ]]
}

@test "trigger: a closed PR is refused" {
  open_pr feat 7 CLOSED
  run "$SD_ACT" trigger
  [ "$status" -ne 0 ]
  [[ "$output" == *"closed"* ]]
}

@test "trigger: no settings.botCommand is refused before any gh call" {
  "$SD_CONFIG" unset --global settings.botCommand
  run "$SD_ACT" trigger
  [ "$status" -ne 0 ]
  [[ "$output" == *"botCommand"* ]]
  [ -z "$(calls)" ]
}

@test "trigger: the local review not covering HEAD is a soft refusal; --force posts" {
  git update-ref -d refs/sheepdog/feat/local
  run "$SD_ACT" trigger
  [ "$status" -ne 0 ]
  [[ "$output" == *"local review"* ]]
  [ -z "$(calls)" ]
  run "$SD_ACT" trigger --force
  [ "$status" -eq 0 ]
  [ "$(pin bot)" = "$(git rev-parse HEAD)" ]
}

@test "trigger: the comment failing pins nothing" {
  touch "$GH/fail-comment"
  run "$SD_ACT" trigger
  [ "$status" -ne 0 ]
  [ -z "$(pin bot)" ]
}
