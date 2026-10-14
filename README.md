# pr-tend

Takes the busy work out of getting a branch to a merged PR and keeping it
current while it's open: up to date with its parent (stack-aware), CI green on
the head SHA, review current, bot comments answered. Scripts observe and act;
an agent (Claude or pi) is invoked only for a bounded judgment step.

Commands:

| Command     | What it does                                              |
|-------------|-----------------------------------------------------------|
| `pr-state`  | Read-only status of a branch's PR, and what to do next    |
| `pr-act`    | Take the next step on a branch (address, restack, push…)  |
| `pr-watch`  | Periodic pass over your branches; optional launchd job    |
| `pr-config` | Show and validate settings                                |

Design notes, still a working draft: [`docs/pr-workflow/design.md`](docs/pr-workflow/design.md).

## Install

```bash
./install.sh        # links bin/pr-* into ~/.local/bin ($LOCAL_BIN to override)
```

Needs on `PATH`: `bash5` (a link to bash 5+; the commands are
`#!/usr/bin/env bash5`), `git`, `gh`, `jq`, and SuperDB `super` **0.3.0**
exactly. `claude` and/or `pi` for the agent steps.

## Interfaces with other tools

- `pr-watch` writes a glyph per worktree to `~/.claude/tab-status/<worktree>.pr`
  (`$STATUS_DIR`), which agent-rig's `tab-status` reads.
- The launchd job is labelled `com.agent-rig.pr-watch`, a holdover from when
  this lived in agent-rig.

## Tests

[bats](https://github.com/bats-core/bats-core). See `CLAUDE.md` for how to run
them and the bash-version caveat.
