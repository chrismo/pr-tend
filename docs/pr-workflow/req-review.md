# PR workflow — requirements review (acceptance walk-through)

> **Being consumed — not for keeping.** Every part of this file moves out as
> soon as it has a home, and is deleted here when it does: built behavior into
> the code and its tests (the README where users need it); unbuilt work, bugs,
> spikes and open decisions into GitHub issues on the
> [sheepdog project board](https://github.com/users/chrismo/projects/6). No
> duplicate docs: don't add anything here that the code or an issue already
> says; link the issue instead. When nothing is left, delete the file. Don't
> treat it as current documentation of anything that exists.

Acceptance cases played through `design.md` on paper, 2026-10-11. Nothing was
run: every item below is a **theory** reasoned from the doc, not an observed
failure. Section references (A2, O6, J3 …) point to `design.md`.

Scenarios walked: happy path (single branch, Claude); stack with parent open,
parent squash-merged, parent unpushed, parent closed; restack conflict;
takeover mid-step; foreign / GitHub-UI pushes; red CI incl. flaky; human
comments; local-review and bot pushback; bot never replying; many branches at
once; merge while a step runs.

Fix in the doc before building: **1, 2, 3, 5, 9**. Each one changes the stored
state or the state machine itself, not just its details.

## Would break the loop

### 3. Lock / in-flight gates only agent steps, not mechanical ones

*Case: parent merges while a child's agent step runs, or while chrismo is
attached.* Watcher step 3 runs A2, A3 and A11 with no in-flight or lock check.
A restack between two of the agent's commits rewrites history under it. During
a takeover, "mechanical observation continues" doesn't say whether mechanical
*acts* continue.

Fix: anything that writes to the worktree or pushes is gated exactly like agent
steps.

### 4. "Step in flight" has no storage, and launchd may kill steps

O8 asks whether a step is in flight, but the storage table has no record for it
(pid, start time). Agent steps take minutes, so a watcher pass must detach
them. From memory, unverified: launchd kills a job's leftover process group
when the job exits unless `AbandonProcessGroup` is set — if so, steps die at
the end of each pass. A step also needs a wall-clock timeout:
`--max-budget-usd` doesn't catch a hang.

### 5. "Done = process exit" can't tell finished from asking

*Case: unclear task; agent commits partial work, then asks a question.* Exit 0,
clean tree, commits ahead → pipeline proceeds to review and the question is
lost.

Fix: the step contract returns an explicit outcome (done / needs-input / gave
up). Claude via `--json-schema`; pi via a parsed sentinel.

### 6. Pushback with no code change loops until the cap

- **Local review:** J3 rejects a finding, nothing changes, check reruns on the
  same HEAD, the reviewer raises the same finding, repeat until cap 3. Needs a
  record of dismissed findings — passed back to the reviewer, or used to pin
  `local`.
- **CI (J2):** "flaky, not ours" → no commit → same red SHA burns both CI
  rounds. A J2 "no change" outcome should go to A6 (rerun) or straight to
  chrismo.

## Gaps in the scenarios

### 7. Child started before its parent is pushed

*Case: `--parent A` while A is still in implement.* `origin/A` doesn't exist,
so A2's `<new-base>` has nothing to point at and `gh pr create --base A` fails.
Either the child waits for the parent's first ship, or the restack target falls
back to local `A`.

### 9. Someone else's fast-forward is treated as a foreign push

GitHub's "Commit suggestion" and "Update branch", and fixer bots
(pre-commit.ci etc.), add commits on top of ours. Those SHAs aren't in our
reflog → escalate. A3 would also be rejected, because nothing ever pulls.

Fix: a reconciliation row "local is an ancestor of remote → `merge --ff-only`".

### 10. Root branches restack every time main moves

*Case: busy repo at work.* Goal 1 for a branch off `main` means restack → push
→ CI rerun → staleness check on every merge to main; it never settles. Root
branches need a policy: restack only on conflict, `mergeable` false, or when
branch protection requires up-to-date.

### 11. Nothing waits on a bot that never replies

O6's "bot replied since trigger?" has no timeout. A bot that's down leaves the
branch at ⏳ indefinitely.

### 12. Takeover while a step is running

`sd act attach` would open an interactive resume of `$U` while a headless
resume of `$U` is still writing the same session. Attach must wait for or kill
the step. The lock also needs a pid + liveness check: a closed terminal skips
the release and stalls the branch silently.

## Smaller items

- **Human threads have no verb.** "Agent, deal with this human comment" is
  likely the most common request and only works through attach. ✅ also ignores
  "changes requested" and missing required approvals.
- **J5 runs in the author's session** — the agent judges whether its own fix
  needs re-review. Better in the isolated reviewer process, like A8.
- **A7 resolves pushback threads.** It resolves after any reply; Cursor's rule
  (cited in prior art) is to resolve only when fully addressed.
- **Takeover section contradicts the state machine.** It resumes "at the
  local-review check", but `check` runs verify first. And if chrismo answered a
  question and there are still no commits, it should re-run implement, not check.
- **`sheepdog.verify` per monorepo app doesn't fit git config** — keys can't vary
  by subdirectory. Needs a file under `.sheepdog/`.
- **No global concurrency cap.** With many enrolled branches, one pass could
  start N `claude -p` at once against one Max subscription.
- **Merge while a step runs.** Step 10 unenrolls, but the agent keeps working on
  a merged branch. Kill the step first.
