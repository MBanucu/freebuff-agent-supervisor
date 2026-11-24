# Freebuff agent supervisor

Run one Freebuff agent per issue in its own git worktree and tmux session.

This was extracted from `wireless-adb-keeper`, where it ran the #100/#101/#102
agents in parallel. The tool is independent of that project: run it from any
git checkout, or point it at one with `--root`.

## What it does

1. creates `.worktrees/<name>` on a new branch from a base ref;
2. writes the brief to `.task.md` in that worktree;
3. starts Freebuff in a detached tmux session `fb-<name>` at **180x55**;
4. waits until the TUI accepts raw input, then sends the "read `.task.md`"
   prompt;
5. shows the pane, branch, commit and PR with `status`, and stops it with
   `stop`.

The agent is told to commit, push and open the PR. The tool never commits,
pushes, merges or deletes anything, and it never modifies the main worktree.

## Requirements

- `freebuff` on `PATH` (or `FREEBUFF_BIN`).
- `tmux`. On NixOS the tool finds it with `nix-shell -p tmux` and caches the
  path; otherwise install it or set `FREEBUFF_TMUX`.
- `gh` authenticated for the PR column and for the generated brief. The tool
  still works without it with `--title`/`--url` or `--no-gh`.

## Install

```bash
chmod +x spawn-freebuff-agent spawn-freebuff-agent-test.sh
```

The scripts need no build step and have no runtime dependencies beyond bash,
git, tmux and Freebuff.

## Usage

Run it from the target repository:

```bash
/path/to/spawn-freebuff-agent start --issue 103 \
  --name 103-example --branch issue/103-example
```

Use `--root /path/to/repo` to target another checkout. The default name is
`issue-<N>`, the default branch is `issue/<N>`, and the default base is `main`.

`--sdk-dir DIR` writes `sdk.dir` into the worktree's ignored
`local.properties`; without it, the target repository's `local.properties` is
copied when present.

Use `--task-file FILE` when an issue needs a custom scope instead of the
generic issue brief. `--dry-run` prints the plan and changes nothing;
`--no-start` creates only the worktree, branch and `.task.md`.

## Inspect and control

```bash
spawn-freebuff-agent list
spawn-freebuff-agent status 103-example --lines 40
spawn-freebuff-agent status 103-example --no-gh
spawn-freebuff-agent attach 103-example   # detach with Ctrl-b d
spawn-freebuff-agent send 103-example "Also run the new test"
spawn-freebuff-agent stop 103-example
```

`status` prints `running=yes|no`, `input=raw|canonical`, the pane tail, the
last commit, whether the worktree is dirty, and any open PR for the branch.
`stop` only kills the tmux session; the worktree and branch remain. Clean them
up explicitly when the PR is merged:

```bash
git worktree remove .worktrees/103-example
git branch -d issue/103-example
```

## The 180x55 rule

The size is not cosmetic. At 120x40 the Freebuff TUI stays in canonical mode
and silently ignores the prompt. `start` waits for `-icanon` and the
`Enter a coding task` line before sending anything, and fails with the last
pane lines if the TUI never becomes ready.

## Safety

- The tool writes only under `.worktrees/` in the target repository, plus
  `.git/info/exclude` entries for `.worktrees/`, `.task.md` and
  `local.properties`.
- A running agent uses its normal shell approvals. Do not attach and type while
  it is working; use `send` for a deliberate follow-up.
- `stop` leaves the branch and worktree in place on purpose.

## Limitations

- This is a TUI supervisor, not a headless API. Status is a pane capture, and
  launching depends on the 180x55/raw-input check.
- Concurrent Freebuff sessions share one account; if the service throttles a
  new session, the pane says `Can't reach Freebuff's servers. Retrying...`.
  The session is left running for inspection.
- The test suite is deviceless: it covers planning, worktree/brief creation,
  exclusions, status, list, duplicate refusal and custom briefs. It does not
  start a fourth Freebuff session.
