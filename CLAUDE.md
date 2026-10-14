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
bats --jobs 10 lib/pr-next.bats bin/pr-*.bats
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

The suites have been run with the sandbox disabled; they have not been checked
inside it.
