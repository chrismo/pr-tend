# Shared by sd act, sd state and sd watch. Source it after lib/config.sh;
# needs bash 5 and super 0.3.0.
#
# See docs/pr-workflow/design.md, "Harness adapter".

# with_timeout <seconds> <cmd...>: kills the command's whole process group
# when time runs out (its children would otherwise hold our output pipe open).
with_timeout() {
  perl -e '
    my $t = shift;
    my $pid = fork // die "fork: $!\n";
    if (!$pid) { setpgrp(0, 0); exec @ARGV or die "exec $ARGV[0]: $!\n" }
    $SIG{ALRM} = sub { kill "TERM", -$pid; print STDERR "timed out after ${t}s\n"; exit 124 };
    alarm $t;
    waitpid $pid, 0;
    exit($? & 127 ? 128 + ($? & 127) : $? >> 8);
  ' "$@"
}

# pin_write <branch> <kind> <sha> <base>: record a review pin and the base
# it was taken against. sd state compares base..pin with the branch's current
# base..HEAD, so a restack (which moves the base) doesn't make a reviewed
# change look changed. Kinds: local, bot, accepted (see design.md, O6).
pin_write() {
  case $2 in local|bot|accepted) ;; *) echo "unknown pin: $2 (local, bot, accepted)" >&2; return 1 ;; esac
  git update-ref -m "pin $2" "refs/sheepdog/$1/$2" "$3" \
    && git update-ref -m "pin $2 base" "refs/sheepdog/$1/$2-base" "$4"
}

# commits_not_ours <reflog> <sha>: how many commits of <sha> no reflog entry reaches.
commits_not_ours() {
  sed -n 's/^./^&/p' <<<"$1" | git rev-list --count --stdin "$2"
}

# step_guidance <setting> <branch> <base> <default-file>: the guidance part of a
# step's prompt: the file settings.<setting> names, else <default-file>. A
# relative path is read from the <base> commit, which the branch's agent can't
# rewrite; an absolute one from disk. A named file that is missing is an error,
# never the default. The same shape fits any step whose guidance is configurable.
step_guidance() {
  local path top
  path=$(prc_get "settings.$1" "$2" false) || return 1
  if [[ -z $path ]]; then
    cat "$4"
  elif [[ $path == /* ]]; then
    [[ -f $path ]] || { echo "settings.$1: no such file: $path" >&2; return 1; }
    cat "$path"
  else
    # From the top, so ./ means the worktree's top wherever the step runs.
    top=$(git rev-parse --show-toplevel) || return 1
    [[ $(git -C "$top" cat-file -t "$3:$path" 2>/dev/null) == blob ]] \
      || { echo "settings.$1: no such file in ${3:0:7}: $path" >&2; return 1; }
    git -C "$top" cat-file blob "$3:$path"
  fi
}

# Claude may read and edit; the pipeline commits, pushes and talks to GitHub.
HARNESS_CLAUDE_ALLOW="Read,Edit,Write,Grep,Glob,Bash(git diff *),Bash(git log *),Bash(git show *),Bash(git status *)"
HARNESS_CLAUDE_DENY="Bash(git commit *),Bash(git push *),Bash(gh *)"
# pi has no per-command bash rules, so no bash at all.
HARNESS_PI_TOOLS="read,edit,write"
# Read-only steps (review, describe) set HARNESS_CLAUDE_ALLOW to this and
# HARNESS_PI_TOOLS to "read" before calling harness_run.
HARNESS_READONLY_ALLOW="Read,Grep,Glob,Bash(git diff *),Bash(git log *),Bash(git show *),Bash(git blame *)"

# harness_object: the JSON object on stdin, or status 1 (not JSON, not an
# object, nothing at all).
harness_object() {
  local r
  r=$(prc_json 'where kind(this) == "record"' 2>/dev/null) && [[ -n $r ]] || return 1
  printf '%s\n' "$r"
}

# harness_result <claude --output-format json output>: the step's result
# object: structured_output, else the result text parsed as JSON; nothing on
# an error result (status 1).
harness_result() {
  prc_json 'where not coalesce(is_error, false)
    | values coalesce(structured_output, parse_sup(coalesce(result, "")), null)' "$1" 2>/dev/null | harness_object
}

# harness_run <harness> <session-id> <new|resume> <timeout> <prompt> <json-schema> [<settings-json>]
# Runs one headless agent step in $PWD; prints the step's JSON result.
# settings-json is prc_step's output: model, effort, provider, args, and for
# claude useApiKey. Claude runs with ANTHROPIC_API_KEY unset unless that is
# true: an exported key overrides the claude.ai login (#68), and the one in a
# shell rc is often not the one to bill. pi can't use the login, so it keeps
# the key.
# The harness's stderr (claude can put protocol JSON there) shows only when
# the step fails, and then all at once: nothing streams while it runs.
harness_run() {
  local h=$1 sid=$2 mode=$3 timeout=$4 prompt=$5 schema=$6 settings=${7:-'{}'} out err rc said
  local model effort provider use_key args fields
  local -a typed=() extra f env=()
  # args last, so a newline in it shifts nothing; the end marker survives $( )
  # stripping the trailing newlines of empty fields.
  fields=$(prc_line 'where kind(this) == "record"
    | values coalesce(model, ""), coalesce(effort, ""), coalesce(provider, ""), coalesce(useApiKey, false), coalesce(args, ""), "<end>"' "$settings") || return 1
  mapfile -t f <<<"$fields"
  [[ ${#f[@]} -ge 6 && ${f[-1]} == "<end>" ]] || return 1
  model=${f[0]} effort=${f[1]} provider=${f[2]} use_key=${f[3]} args=$(printf '%s\n' "${f[@]:4:${#f[@]}-5}")
  read -ra extra <<<"$args"
  # An interrupted step leaves this file behind (no trap: harness_run runs in
  # its caller's shell, whose traps it would replace).
  err=$(mktemp) || return 1
  case $h in
    claude)
      [[ $use_key == true ]] || env=(env -u ANTHROPIC_API_KEY)
      if [[ -n $model ]]; then typed+=(--model "$model"); fi
      if [[ -n $effort ]]; then typed+=(--effort "$effort"); fi ;;
    pi)
      if [[ -n $provider ]]; then typed+=(--provider "$provider"); fi
      if [[ -n $model ]]; then typed+=(--model "$model"); fi
      if [[ -n $effort ]]; then typed+=(--thinking "$effort"); fi ;;
  esac
  case $h in
    claude)
      local -a sess=(--session-id "$sid")
      [[ $mode == resume ]] && sess=(--resume "$sid")
      # The prompt goes first: --allowedTools and --disallowedTools are variadic
      # and would swallow a trailing one.
      out=$(with_timeout "$timeout" "${env[@]}" claude -p "$prompt" "${sess[@]}" --output-format json --json-schema "$schema" \
              --permission-mode acceptEdits --allowedTools "$HARNESS_CLAUDE_ALLOW" \
              --disallowedTools "$HARNESS_CLAUDE_DENY" "${typed[@]}" "${extra[@]}" </dev/null 2>"$err") \
        && harness_result "$out"
      ;;
    pi)
      # pi has no schema flag: the prompt asks for a final ```json block.
      out=$(with_timeout "$timeout" pi -p --session-id "$sid" --tools "$HARNESS_PI_TOOLS" "${typed[@]}" "${extra[@]}" \
              "$prompt"$'\n\nEnd your reply with the result as one ```json fenced block matching this JSON Schema:\n'"$schema" \
              </dev/null 2>"$err") \
        && awk '/^```json/ { buf = ""; on = 1; next } /^```/ { if (on) last = buf; on = 0; next }
                on { buf = buf $0 "\n" } END { printf "%s", last }' <<<"$out" | harness_object
      ;;
    *) echo "unknown harness: $h (claude or pi)" >&2; rm -f "$err"; return 1 ;;
  esac
  rc=$?
  if (( rc != 0 )); then
    tail -n 40 "$err" >&2
    # The end of the harness's own account of the failure: claude's result
    # text, else an error result's subtype (e.g. error_max_turns), else
    # stdout that isn't JSON; pi's reply.
    said=$out
    if [[ $h == claude ]]; then
      said=$(prc_line 'where kind(this) == "record"
        | values coalesce(nullif(result, ""), coalesce(is_error, false) ? subtype : null, "")
        | where this != ""' "$out" 2>/dev/null) || said=$out
    fi
    [[ -z $said ]] || tail -n 20 <<<"$said" >&2
  fi
  rm -f "$err"
  return "$rc"
}
