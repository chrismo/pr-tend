# sheepdog

Takes the busy work out of getting a branch to a merged PR and keeping it
current while it's open: up to date with its parent (stack-aware), CI green on
the head SHA, review current, bot comments answered. Scripts observe and act;
an agent (Claude or pi) is invoked only for a bounded judgment step.

One command, `sd`, with a verb (`sd help` lists them):

| Command      | What it does                                              |
|--------------|-----------------------------------------------------------|
| `sd state`   | Read-only status of a branch's PR, and what to do next    |
| `sd act`     | Start a branch, then take its next step (address, push…)  |
| `sd watch`   | Periodic pass over your branches; optional launchd job    |
| `sd config`  | Show and validate settings                                |
| `sd migrate` | Move a pr-tend install's state to sheepdog's names        |

Design notes, still a working draft: [`docs/pr-workflow/design.md`](docs/pr-workflow/design.md).

## Install

```bash
./install.sh        # links bin/sd into ~/.local/bin ($LOCAL_BIN to override)
```

Needs on `PATH`: `bash5` (a link to bash 5+; the commands are
`#!/usr/bin/env bash5`), `git`, `gh`, `jq`, and SuperDB `super` **0.3.0**
exactly. `claude` and/or `pi` for the agent steps.

## Interfaces with other tools

- `sd watch` writes a glyph per worktree to `~/.claude/tab-status/<worktree>.pr`
  (`$STATUS_DIR`), which agent-rig's `tab-status` reads.
- The launchd job is labelled `com.sheepdog.watch`. `sd watch install` and
  `uninstall` also retire its earlier labels, `com.agent-rig.pr-watch` and
  `com.pr-tend.pr-watch`.

## Coming from pr-tend

sheepdog was pr-tend until 2026-10-15: `pr-act push` is now `sd act push`, and
its state moved to new names (`refs/sheepdog/`, `~/.config/sheepdog/`, git
config `sheepdog.*`, `SHEEPDOG_*` env vars). On a machine that ran pr-tend, after
`./install.sh`:

```bash
sd migrate --dry-run   # what it would move, and anything it can't
sd migrate
sd watch install       # if the watcher ran there; replaces the old job
```

## Tests

[bats](https://github.com/bats-core/bats-core). See `AGENTS.md` for how to run
them and the bash-version caveat.
