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
5. shows the pane, branch, result and PR with `status`, and stops it with
   `stop`;
6. optionally watches the run and stops the session when the agent reports a
   result, or when the pane has been idle past a window (`--auto-stop`).

The agent is told to commit, push and open the PR, then write a small
`.agent-result` file. The tool never commits, pushes, merges or deletes
anything, and it never modifies the main worktree.

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

`--auto-stop` starts a detached watcher after the prompt is sent. It stops
`fb-<name>` as soon as the agent writes `.agent-result`, or when the pane has
been idle for `--idle-seconds` (default 120) with `--poll` seconds between
checks (default 5):

```bash
spawn-freebuff-agent start --issue 103 --auto-stop
```

The watcher writes transitions and the stop evidence to
`.worktrees/103/.supervisor.log`, so the run is inspectable after the session
is gone.

## Completion

Freebuff 0.2.38 is a TUI and has no one-shot or headless mode; the process
stays alive at its input prompt after the agent finishes. There is no exit
event to subscribe to, so the supervisor uses two signals.

**The result file (preferred).** The generated brief ends with:

```
state=done            # done, blocked or failed
pr=<PR URL, or none>
commit=<short sha, or none>
tests=<one line: what you ran>
```

The file is written in the worktree root, is covered by
`.git/info/exclude`, and is never committed. `blocked` and `failed` count as
finished: a draft PR plus an explanation is a valid outcome. A custom
`--task-file` brief must include the same instruction, otherwise only the
idle signal applies.

**The idle pane (fallback).** `watch` captures the visible pane, looks at the
bottom lines, and treats the session as idle when the input prompt is visible,
no busy marker is present, and the pane is unchanged for the window. A shell
approval prompt, rate-limit notice or the concurrent-session overlay is never
treated as idle. The current defaults match `esc to interrupt` and spinner
glyphs for busy, and the approval, rate-limit and concurrent-session strings
for protected. These markers are TUI chrome and can change between Freebuff
releases; the result file does not depend on them.

`status` reports both views:

```
state=done                  # from .agent-result
session_state=done          # live: done, idle, working, refused or missing
```

## Inspect and control

```bash
spawn-freebuff-agent list
spawn-freebuff-agent status 103-example --lines 40
spawn-freebuff-agent status 103-example --no-gh
spawn-freebuff-agent attach 103-example   # detach with Ctrl-b d
spawn-freebuff-agent send 103-example "Also run the new test"
spawn-freebuff-agent watch 103-example --idle-seconds 120 --poll 5
spawn-freebuff-agent autostop 103-example
spawn-freebuff-agent stop 103-example
spawn-freebuff-agent gc --dry-run
```

`watch` prints `state=working|idle|done|refused|missing`, and exits `0` when
the result file appears or the pane has been idle past the window, `1` on
`--timeout`, and `2` when the session is gone. It never stops anything.
`autostop` is `watch` followed by a stop and an evidence record; `start
--auto-stop` runs it detached.

`list` prints the branch, session, running flag, live state and idle time.
`status` prints the result state, `session_state`, idle seconds, the pane
tail, the last commit, whether the worktree is dirty, and any open PR for the
branch.

`gc` stops sessions that are `done`, stuck on the concurrent-session overlay,
idle for more than `--idle-hours` (default 12), or — with `--all` — `fb-*`
sessions whose worktree no longer exists. Busy and approval panes are skipped
with a reason, and `--dry-run` only reports. `gc` never removes worktrees or
branches; it prints the cleanup commands instead:

```bash
git worktree remove .worktrees/103-example
git branch -d issue/103-example
```

`stop` only kills the tmux session; the worktree and branch remain.

## The 180x55 rule

The size is not cosmetic. At 120x40 the Freebuff TUI stays in canonical mode
and silently ignores the prompt. `start` waits for `-icanon` and the
`Enter a coding task` line before sending anything, and fails with the last
pane lines if the TUI never becomes ready.

A pane that never becomes ready — for example the concurrent-session overlay
— is deliberately left running for inspection; `gc` stops it because it can
never become usable.

## Safety

- The tool writes only under `.worktrees/` in the target repository, plus
  `.git/info/exclude` entries for `.worktrees/`, `.task.md`,
  `.agent-result`, `.supervisor.log` and `local.properties`.
- A running agent uses its normal shell approvals. Do not attach and type while
  it is working; use `send` for a deliberate follow-up.
- Auto-stop and `gc` only kill `fb-<name>`, after appending the pane tail,
  commit, dirty flag and PR to `.worktrees/<name>/.supervisor.log`.
- `stop`, auto-stop and `gc` leave the branch and worktree in place on purpose.

## Limitations

- This is a TUI supervisor, not a headless API. Status is a pane capture, and
  launching depends on the 180x55/raw-input check. The idle markers are tied to
  the Freebuff release; the result file is the stable signal.
- Concurrent Freebuff sessions share one account; if the service throttles a
  new session, the pane says `Can't reach Freebuff's servers. Retrying...`.
  The session is left running for inspection, and `gc` will not treat the
  rate-limit notice as finished.
- The test suite is deviceless: a fake tmux serves fixture panes and records
  kills, so it covers the result protocol, state transitions, autostop and
  `gc` decisions without a Freebuff session, account slot, `gh` or network.
  It does not exercise the real TUI; verify marker changes with one controlled
  run when upgrading Freebuff.
