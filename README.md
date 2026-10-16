# <img src="img/sam-sheepdog-face.png" alt="Sam Sheepdog" width="110" align="middle"> sheepdog

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

Design notes, consumed into issues and kept for now:
[`docs/pr-workflow/design.md`](docs/pr-workflow/design.md). Decisions are
recorded in the Decision issues on the
[project board](https://github.com/users/chrismo/projects/6); the rules agents
build by are in `AGENTS.md`.

## Install

```bash
./install.sh        # links bin/sd into ~/.local/bin ($LOCAL_BIN to override)
```

Needs on `PATH`: `bash5` (a link to bash 5+; the commands are
`#!/usr/bin/env bash5`), `git`, `gh`, `jq`, and SuperDB `super` **0.3.0**
exactly. `claude` and/or `pi` for the agent steps.

## Agent credentials

Claude steps run with `ANTHROPIC_API_KEY` unset, so `claude -p` uses the
claude.ai login (an exported key would override it, and a key in a shell rc is
often not the one to bill). To bill the key instead, set
`harnesses.claude.useApiKey` to `true` (`sd config set --global --json
harnesses.claude.useApiKey true`). pi can't use the claude.ai login, so it
keeps the key, or runs on the provider its block names.

## Agent steps

`sd act implement`, `address` and `describe` each run one headless agent step
(`claude -p` or `pi -p`) in the branch's session, as does `restack --resolve`
under the `implement` step; `start` runs implement unless `--no-implement`,
and `ship` runs describe unless HEAD already has a stored description.
`sd act review`'s default reviewer runs in a fresh read-only session every
time, so it never shares the author's context; a custom reviewer only has to
keep the contract below, so isolation is up to it. `sd config step <step>`
shows the harness, model and effort a step uses. The agent edits; sheepdog
commits, pushes and talks to GitHub.

Each step's prompt is the step's guidance, then a fixed contract (what the
agent may do, what it returns). A repo replaces a step's guidance by committing
`.sheepdog/<step>.md`: `implement`, `review-fix`, `review`, `describe`,
`address`, `resolve` or `ci-fix`. sheepdog reads it from the branch's base
commit, so a branch can't rewrite its own guidance. `settings.<step>Prompt`
(e.g. `implementPrompt`, `reviewFixPrompt`) names another file and wins over
`.sheepdog/`: a relative path is read from the base commit too, an absolute
one from disk. When no base commit can be trusted (no base pin, no default
branch to fork from), the `.sheepdog/` file is skipped for the shipped
default, and a relative path is an error. The shipped defaults are in
`lib/prompts/`.

A custom local reviewer (`settings.localReview`) keeps the contract in
`libexec/sd-review-local`'s header: `SHEEPDOG_BASE`, `SHEEPDOG_HEAD` and
`SHEEPDOG_TASK` in, a JSON list of findings out.

## Interfaces with other tools

- `sd watch` writes a glyph per worktree to `~/.claude/tab-status/<worktree>.pr`
  (`$STATUS_DIR`), which agent-rig's `tab-status` reads. Two watched
  same-named worktrees on one branch get none, since tab-status couldn't tell
  whose it is.
- `sd watch glyph [<path>]` prints the glyph for the worktree holding `<path>`
  (default `.`) while it's still on the branch checked, from
  `$SHEEPDOG_STATE_DIR/glyphs`. It is exact by path and fast (no super, no
  GitHub), for a shell prompt or a tab title.
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
