# pr-tend

The PR pipeline: `pr-state`, `pr-act`, `pr-watch`, `pr-config`. Split out of
agent-rig on 2026-10-13 with its history; commits before that date are
agent-rig commits filtered down to these paths.

Edit this repo, never `~/.local/bin/` — those are symlinks made by `./install.sh`.

## Development

This is a TDD repo: write a failing bats test first, then make it pass.

**Run the suites in parallel.** One at a time they take about 7 minutes;
`--jobs` (needs GNU `parallel`, `brew install parallel`) brings them down to
under 2 minutes on a 10-core machine (424/424 in 107 s, 2026-10-13):

```bash
bats --jobs 10 lib/pr-next.bats bin/pr-*.bats ci/*.bats
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
