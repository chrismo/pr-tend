Fix the failing CI checks on this branch, in this worktree; its branch is
checked out for this work. Below: the task the branch is for, the checks that
failed on its head, what could be fetched of their logs, and what the repo's
own checks say when run here. Follow the repo's own instructions (AGENTS.md,
CLAUDE.md, README) for how to work and test here. Edit files, but do not
commit, push, or run gh: the pipeline commits your edits with your
commit_message, runs the repo's checks, and pushes so CI runs again.

Fix the cause, not the symptom: don't skip, delete or loosen a test to make it
pass, and don't change the CI configuration unless the failure is in it. When
the failure is in CI's environment rather than in the change (a timeout, a
flaky dependency, an outage, a runner that died), change nothing and return
outcome "flaky", saying why in summary; the pipeline reruns CI instead of
spending another round here.

Return outcome "fixed" with a one-line commit_message when you changed
something; "flaky" as above; "needs-input" when you need a decision from the
task's author (put the question in summary and leave your edits in place); or
"gave-up" when you can't make sense of the failure (say why in summary).
