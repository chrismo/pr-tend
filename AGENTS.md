# pr-tend

The PR pipeline: `pr-state`, `pr-act`, `pr-watch`, `pr-config`. Split out of
agent-rig on 2026-10-13 with its history; commits before that date are
agent-rig commits filtered down to these paths.

Edit this repo, never `~/.local/bin/` — those are symlinks made by `./install.sh`.

## Workflow

pr-tend tends its own PRs, so code changes go through them:

- Branch, then `pr-act push`, `gh pr create`, `pr-act enroll`. Follow
  `pr-state`'s NEXT from there.
- Dependent work stacks on the parent's branch (`gh pr create --base
  <parent>`). Enroll while the PR still targets the parent: enroll records
  the lineage that GitHub's retarget on merge erases. Keep it current with
  `pr-act restack && pr-act push`.
- chrismo merges: squash, delete the branch.
- Docs-only and issue-tracking edits may go straight to `main`.
- `docs/pr-workflow/` is being consumed, not kept: when work from it is built or
  filed as an issue, delete that part of the doc in the same change.

### Or run pr-tend against the sandbox

Dogfooding on this repo's own PRs is the default, not a rule.
[`chrismo/pr-tend-sandbox`](https://github.com/chrismo/pr-tend-sandbox)
(checkout `../pr-tend-sandbox`) is a throwaway Go repo with RWX CI that pr-tend
can run against when running it here isn't advisable:

- a spike that needs real merges, force-pushes or branch-protection changes
- a CI state on demand: its `ci/mode` makes CI pass, fail, flake, crawl or hang
- a pr-tend build you don't trust yet near real PRs

Pick whichever fits the task; one piece of work can use both. The sandbox's
AGENTS.md has its rules and the setup that keeps pr-tend's state there away
from chrismo's real config, glyphs and launchd job.

## Development

This is a TDD repo: write a failing bats test first, then make it pass.

**Run the suites in parallel.** One at a time they take about 7 minutes;
`--jobs` (needs GNU `parallel`, `brew install parallel`) brings them down to
under 2 minutes on a 10-core machine (424/424 in 107 s, 2026-10-13):

```bash
bats --jobs 10 lib/*.bats bin/pr-*.bats ci/*.bats
bats install.bats
```

**Check which bash bats is using before trusting a green run.** `bats` is
`#!/usr/bin/env bash`, so test bodies run under whichever bash is first on
`PATH`. Under bash 3.2 a `[[ ]]` or `(( ))` that is not the last statement of a
test body does not fail the test under `set -e`, so the suite passes no matter
what it claims. Bash 5 fails it correctly.

```bash
bash --version | head -1
PATH="/opt/homebrew/opt/bash/bin:$PATH" bats ...   # if 3.2 comes first
```

**Every script is `#!/usr/bin/env bash5`, `install.sh` included.** Test them
by running them, not sourcing, so the shebang picks the bash. agent-rig's
`install.sh` makes the `~/.local/bin/bash5` link; without it a script fails
with `env: bash5: No such file or directory`.

The suites pass inside Claude Code's sandbox as well as outside it (424/424 in
104 s, 2026-10-13).

## CI (RWX)

`.rwx/tests.yml` runs every suite on Ubuntu for PRs and pushes to `main`, through
Captain (`.captain/config.yml`) via `ci/test`. Run it without pushing; `rwx run`
sends local edits as a patch:

```bash
rwx run .rwx/tests.yml --wait
rwx logs --task test <run-id>
```

One 16-CPU task, not Captain shards: `bats --jobs` balances tests across CPUs
better than Captain balances 11 files across runners (37 s vs 77 s, 2026-10-14).

Linux has no `plutil`, so the five pr-watch tests that validate the launchd
plist skip there (`needs_plutil`). They still run on macOS.
