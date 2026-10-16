# What to do next on a branch, from its sd state JSON. Source it after
# lib/config.sh; needs bash 5 and SuperDB.
#
# A step is {key, who, say, cmd}. who is who does it once it's automated:
#   you    chrismo's judgment     agent  a model step
#   run    mechanical             wait   nothing to do yet
# cmd is what to run by hand meanwhile (null: no command yet).
#
# Ordering of the loop's own steps, after what blocks everything (stale refs,
# human items): restack, agent fixes, one push, then review and wait; the push
# leads because every push restarts CI (#79 Design record).

# Behind the default branch alone is no step: it moves too often to chase.
# A conflict with it is, and so is a restack after the parent merged.
# A PR in a native GitHub stack (pr.stack) is never restacked or retargeted
# here: GitHub does that itself when the PR below merges (and rewrites the
# branch), and refuses base edits and plain merges. The same cases get one
# stack step instead: stack-rewritten pulls GitHub's rewrite with gh stack sync
# (notified, like foreign; only once the parent merged, GitHub's reason to
# rewrite: before that a foreign push is plain foreign); stack-conflict is
# chrismo's, through gh stack (notified, like conflict); stack-sync, also gh
# stack sync, rebases a stack behind its open parent or GitHub's BEHIND
# (mechanical, like behind);
# stack-wait is GitHub's turn, with no command: the parent merged and the PR
# still targets it or still carries its commits. A merged parent is never
# chased, and sd-parent may still name it after GitHub retargeted the PR.
# Only bot items are ever marked i, so owed_bot - info is the blocking bot count.
# on() and n() come from lib/config.sh's PRC_FNS: a null or missing
# field compares to nothing in SuperDB, and they make it false and 0.
PRN_QUERY='fn plural(k, w): f"{k} {w}{k == 1 ? "" : "s"}"
fn step(key, who, say, cmd): {key: key, who: who, say: say, cmd: cmd}
fn covers(p): on(p.status in ["covered", "rewritten-same"])
fn trails(p): on(p.status in ["uncovered", "rewritten-changed", "unknown"])
fn why_blocked(m): m == "BLOCKED" ? "the merge is blocked"
                   : m == "DIRTY" ? "there are conflicts" : m == "DRAFT" ? "it'"'"'s a draft" : lower(m)
values {...s, remote}
| put open:=(pr is null or on(pr.state == "OPEN")), has_pr:=on(pr.state == "OPEN"),
      foreign:=(on(push.remote_ours == false) and n(push.theirs) > 0),
      native:=(coalesce(pr.stack, null) is not null),
      stack_waiting:=(coalesce(pr.stack, null) is not null and on(parent.merged)
                      and (on(pr.base != sync.default) or not on(sync.parent_in_history == false))),
      bot_blocking:=(n(threads.owed_bot) - n(threads.info)),
      to_push:=(push.remote_sha is null or n(push.ahead) > 0),
      chase:=(on(sync.target != sync.default) or on(parent.merged)),
      undone:=(n(sync.undone) > 0),
      merge_state:=coalesce(pr.merge_state, "UNKNOWN"),
      gh_behind:=on(pr.merge_state == "BEHIND"),
      draft_ready:=(on(pr.draft) and not (push.remote_sha is null or n(push.ahead) > 0)
                    and not (on(push.remote_ours == false) and n(push.theirs) > 0)
                    and (on(ci.verdict == "green") or on(ci.verdict == "none"))),
      review_required:=on(pr.review_decision == "REVIEW_REQUIRED"),
      stacked:=(on(pr.base != sync.default) and (on(parent.pr.state == "OPEN") or on(parent.merged))),
      parent_closed:=(on(pr.base != sync.default) and on(parent.pr.state == "CLOSED")),
      restack:=(sync.old_base is null ? f"git rebase {remote}/{sync.target}"
                : f"git rebase --onto {remote}/{sync.target} {sync.old_base[0:12]}"),
      need_review:=((on(pr.state == "OPEN") or trails(review.local) or trails(review.bot) or trails(review.accepted)
                     or on(review.findings.at_head == false))
                    and not (covers(review.local) or covers(review.bot) or covers(review.accepted))),
      fixing:=(on(review.findings.at_head) and not (covers(review.local) or covers(review.bot) or covers(review.accepted))),
      bot_due:=(coalesce(bot.command, null) is not null and covers(review.local)
                and not covers(review.bot) and not covers(review.accepted))
| unnest [
    on(pr.state == "MERGED") ? step("merged", "run", "merged: drop the branch'"'"'s pins and enrollment, then remove this worktree", "sd act forget") : null,
    on(pr.state == "CLOSED") ? step("closed", "you", "PR closed without merging", null) : null,
    open and len(errors) > 0
      ? step("errors", "you", f"{plural(len(errors), "error")}: the steps below may be wrong", "sd state --json") : null,
    open and on(fresh == false)
      ? step("stale", "run", "fetch: GitHub is ahead of your remote refs, so the steps below may be wrong",
           f"git fetch --prune {remote}") : null,
    open and on(session.locked)
      ? step("attached", "wait", "attached: the branch'"'"'s session is open interactively; agent steps wait until it exits", null) : null,
    open and native and foreign and on(parent.merged)
      ? step("stack-rewritten", "you",
             f"{remote}/{branch} has {plural(push.theirs, "commit")} this copy has never had, GitHub'"'"'s rewrite of stack #{pr.stack.number} ({pr.stack.position} of {pr.stack.size}) most likely: pull it (git log HEAD..{remote}/{branch} to look first)",
             "gh stack sync") : null,
    open and foreign and not (native and on(parent.merged))
      ? step("foreign", "you", f"{remote}/{branch} has {plural(push.theirs, "commit")} this copy has never had",
             f"git log HEAD..{remote}/{branch}") : null,
    open and n(threads.owed_human) > 0
      ? step("human", "you", f"reply to {plural(threads.owed_human, "human item")}", "sd state --long") : null,
    open and undone
      ? step("restack-undone", "you",
             f"the restack was undone ({sync.undone} of {sync.target}'"'"'s commits {sync.undone == 1 ? "is a copy" : "are copies"} on {branch}; a plain git push after a restack?): redo it, and don'"'"'t sd act push before that, which would publish the copies",
             f"{restack} && sd act push") : null,
    open and native and not undone and not foreign and not parent_closed and not stack_waiting and on(sync.up_to_date == false) and on(sync.conflict)
      ? step("stack-conflict", "you", f"conflicts with {sync.target} in GitHub stack #{pr.stack.number} ({pr.stack.position} of {pr.stack.size}): resolve it through gh stack, not sd act restack",
             "gh stack sync") : null,
    open and native and not undone and not foreign and not parent_closed and not on(sync.conflict)
         and ((on(sync.up_to_date == false) and on(sync.target != sync.default)) or (gh_behind and not stack_waiting))
      ? step("stack-sync", "run", f"behind {sync.target} in GitHub stack #{pr.stack.number} ({pr.stack.position} of {pr.stack.size}): gh stack rebases it, not sd act restack",
             "gh stack sync") : null,
    open and stack_waiting and not undone and not foreign and not parent_closed
      ? step("stack-wait", "wait", f"waiting on GitHub to retarget and rewrite this PR (stack #{pr.stack.number})", null) : null,
    open and not native and not undone and not parent_closed and on(sync.up_to_date == false) and on(sync.conflict)
      ? step("conflict", "agent", f"restack onto {sync.target} conflicts: resolve it", "sd act restack --resolve") : null,
    open and not native and not undone and not parent_closed and on(sync.up_to_date == false) and not on(sync.conflict) and chase
      ? step("behind", "run", f"restack onto {sync.target} ({sync.behind} behind)",
             sync.old_base is null ? restack : "sd act restack")
      : has_pr and not native and not undone and not parent_closed and not on(sync.conflict) and gh_behind
      ? step("behind", "run", f"restack onto {sync.default} ({n(sync.behind)} behind): GitHub requires branches to be up to date",
             "sd act restack") : null,
    has_pr and on(ci.verdict == "red") and on(ci.for_head) and not to_push
      ? step("ci-red", "agent", f"fix CI: {join(ci.failing, ", ")}", "sd act ci-fix") : null,
    open and bot_blocking > 0
      ? step("bot", "agent", f"address {plural(threads.owed_bot, "bot item")}", "sd act address") : null,
    open and bot_blocking == 0 and n(threads.info) > 0
      ? step("read", "you", f"read {plural(threads.info, "bot item")} in sd state --long, then ack", "sd act ack") : null,
    open and not foreign and not undone and to_push
      ? step("push", "run", push.remote_sha is null ? f"push: not on {remote} yet"
             : on(push.diverged) ? f"force-push {plural(coalesce(sync.ahead, push.ahead), "commit")} (rewritten); a plain git push is rejected, and pulling would undo the rewrite"
             : f"push {plural(push.ahead, "commit")}", "sd act push") : null,
    pr is null and len(errors) == 0 ? step("open-pr", "run", "ship: push, open a draft PR", "sd act ship") : null,
    has_pr and draft_ready and not need_review and not bot_due
      ? step("draft", "run", "CI green and reviewed: mark the PR ready for review", "gh pr ready") : null,
    open and fixing and not on(review.findings.declined) and review.findings.round < review.findings.cap
      ? step("review-fix", "agent", f"fix {plural(review.findings.n, "review finding")} (round {review.findings.round}/{review.findings.cap})",
             "sd act implement")
      : open and fixing
      ? step("review-decide", "you",
             f"{on(review.findings.declined) ? f"the agent declined {plural(review.findings.n, "review finding")}"
                : f"{plural(review.findings.n, "review finding")} after {review.findings.round} rounds"}: fix {review.findings.n == 1 ? "it" : "them"}, or accept HEAD as reviewed (sd state --long lists them)",
             "sd act review --accept")
      : open and need_review ? step("review", "agent", "review the changes since the last review", "sd act review") : null,
    has_pr and not to_push and not foreign and bot_due
      ? step("bot-trigger", "run", f"trigger the review bot ({bot.command})", "sd act trigger") : null,
    has_pr and on(ci.verdict == "inconclusive") ? step("ci-rerun", "run", "rerun cancelled CI", "gh pr checks") : null,
    has_pr and not to_push and (on(ci.verdict == "pending") or on(ci.for_head == false))
      ? step("ci-wait", "wait", on(ci.verdict == "pending") ? "CI running" : "CI hasn'"'"'t reported on HEAD yet",
             "gh pr checks --watch") : null,
    has_pr and parent_closed
      ? step("parent-closed", "you", f"{parent.name} (#{parent.pr.number}) was closed without merging: decide what this PR targets", null) : null,
    has_pr and stacked and on(parent.merged) and not native
      ? step("retarget", "run", f"{pr.base} already merged: point this PR at {sync.default}", "sd act retarget") : null,
    has_pr and review_required
      ? step("review-wait", "wait", len(coalesce(pr.review_requests, [])) > 0
             ? f"waiting on review from {join(pr.review_requests, ", ")}" : "waiting on a required review", null) : null,
    has_pr and stacked and not on(parent.merged)
      ? step("parent-wait", "wait", f"waiting on {parent.name} (#{parent.pr.number}) to merge first", null) : null,
    has_pr and not review_required and not stacked and not parent_closed and not gh_behind and not on(pr.draft)
      ? (merge_state in ["CLEAN", "UNSTABLE", "HAS_HOOKS"] ? step("ready", "you", "ready to merge", native ? f"gh stack merge {pr.number}" : "gh pr merge")
         : merge_state == "UNKNOWN" ? step("merge-wait", "wait", "GitHub hasn'"'"'t decided whether it can merge yet", null)
         : step("blocked", "you", f"GitHub says {why_blocked(merge_state)}: see why", "gh pr view --web")) : null
  ]
| where this is not null
| aggregate steps:=collect(this)
| values coalesce(steps, [])
| values (len(this) > 1 and this[len(this)-1].key in ["ready", "merge-wait", "blocked"]) ? this[0:len(this)-1] : this'

# prn_next <remote>: sd state JSON on stdin; prints the steps as a JSON array, first is next.
prn_next() {
  local state remote kind
  state=$(cat)
  remote=$(prc_json_string "$1") || return
  kind=$(prc_line 'values kind(this)' "$state") || return
  [[ $kind == record ]] || { echo "lib/next.sh: sd state JSON must be one record" >&2; return 1; }
  prc_json "$PRN_QUERY" "{\"remote\": $remote, \"s\": $state}"
}

# prn_lines [one|all]: steps on stdin; one adds a count of the rest, all lists them as "then".
prn_lines() {
  local mode=${1:-one} out more=""
  local -a ls
  out=$(prc_line 'unnest this
    | values f"{who}{"     "[0:5-len(who)]}  {say}{cmd is null ? "" : f"  → {cmd}"}"') || return
  [[ -n $out ]] || return 0
  mapfile -t ls <<<"$out"
  if [[ $mode == all ]]; then
    printf 'NEXT  %s\n' "${ls[0]}"
    (( ${#ls[@]} == 1 )) || printf 'then  %s\n' "${ls[@]:1}"
  else
    (( ${#ls[@]} == 1 )) || more="  (+$(( ${#ls[@]} - 1 )) more)"
    printf 'NEXT  %s%s\n' "${ls[0]}" "$more"
  fi
}
