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
treated as idle.

Markers, captured from 0.2.38:

- idle: `▍Enter a coding task or / for commands`
- busy: `thinking...` / `working...` with a `■ Esc` hint, plus `esc to
  interrupt` and the spinner glyphs from other builds
- busy while a turn is in flight: `Add to the current task (/ for commands)` —
  no idle marker, so it is never mistaken for idle
- protected: the concurrent-session overlay (`concurrent-session limit`) is
  rejected outright and reported as `refused`; the approval/rate-limit strings
  are only consulted when the resting prompt is absent

The order of those checks matters. `session_state` reads the result file, then
the concurrent-session overlay, then the busy markers, then the resting prompt,
and only then the protected strings. The resting prompt outranks them because
the startup banner `Can't reach Freebuff's servers. Retrying…` lands inside the
same 12-line window: while it was checked first, a finished session carrying
that banner reported `working` forever and was never reaped.

A pane with neither marker is reported as `working`, which is the safe
failure mode: `watch` waits instead of stopping. These markers are TUI chrome
and can change between Freebuff releases; the result file does not depend on
them.

**The approval chrome is unverified in 0.2.38.** This build does not ask. It
ran an off-project `touch /tmp/...`, and then — in a repository with
`.agents/rules.md` and without `--trust-agents` — an `rm -rf` aimed outside the
worktree: the pane printed `$ rm -rf ...` and the path was gone, with no prompt
and no trust dialog. The `approval|approve|Allow once|Run command|permission`
strings therefore never match a real pane here. They are kept as a conservative
backstop so a build that does prompt is never mistaken for idle; any pane
without the resting prompt already reports `working` by fallback, so nothing
depends on them.

`status` reports both views:

```
state=done                  # from .agent-result
session_state=done          # live: done, idle, working, refused or missing
```

## Inspect and control

```bash
spawn-freebuff-agent list
spawn-freebuff-agent sessions
spawn-freebuff-agent status 103-example --lines 40
spawn-freebuff-agent status 103-example --no-gh
spawn-freebuff-agent attach 103-example   # detach with Ctrl-b d
spawn-freebuff-agent send 103-example "Also run the new test"
spawn-freebuff-agent watch 103-example --idle-seconds 120 --poll 5
spawn-freebuff-agent autostop 103-example
spawn-freebuff-agent stop 103-example            # hard kill
spawn-freebuff-agent stop 103-example --graceful # end the turn first
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

`sessions` is the inventory: one row per `fb-*` session **and** per worktree,
with `WORKTREE yes|missing`, the attached `autostop` watcher (`pid:N`, `dead`
or `-`), the result state, the branch and the open PR. It starts from
`tmux list-sessions`, so a session with no worktree appears there instead of
only being found when `gc --all` kills it; `list` also names such orphans.
`--no-gh` skips the PR column.

`stop` is a hard kill. `stop --graceful` sends `Escape` to end the turn, waits
up to `--wait` seconds (default 20) for the pane to reach `done`, `idle` or
`refused`, then stops and appends `pane_state=`, `interrupted=` and the wait
to `.supervisor.log`. If the pane is still `working` when the window expires
it stops nothing and exits 1, so a kill cannot land between an edit and its
commit by accident.

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

A pane that never becomes ready — for example the concurrent-session overlay —
can never accept the brief, so `start` prints the last pane lines and stops
that session, leaving the worktree and branch in place.

Because every session shares one account, `start` checks capacity before it
spends a worktree: `--max-sessions N` refuses to start while N `fb-*` sessions
are live, and `--wait-slot [SECONDS]` (default 300, requires
`--max-sessions`) polls until one goes away. A refused `start` creates nothing
at all.

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
  `start` stops a launch that never takes input (the worktree stays), while a
  session throttled mid-run is left alone. The banner is drawn above the
  resting prompt, so such a session reads as `idle` and `gc` only reaps it
  after `--idle-hours` — never on sight.
- The test suite is deviceless: a fake tmux serves fixture panes, several
  session names and recorded kills, so it covers the result protocol, state
  transitions, autostop and `gc` decisions, the `sessions` inventory, graceful
  stop and the capacity pre-flight without a Freebuff session, account slot,
  `gh` or network.
  It does not exercise the real TUI; verify marker changes with one controlled
  run when upgrading Freebuff.

## Upstream: expect the TUI to stay the only mode

This tool exists because Freebuff has no one-shot or headless mode. That is not
an oversight waiting to be fixed, and it should not be planned around one
arriving. Checked on 2026-11-25 against Freebuff 0.2.38 and the upstream
tracker:

- The official docs state it as a property: *"It is an interactive client: it
  does not accept an initial prompt as an argument, and it is not a scriptable
  JSON mode."* The project's own comparison writing says the same: *"The CLI is
  a terminal UI with no non-interactive mode, which rules out CI and scripts."*
- The reason is the funding model, not effort. Freebuff is ad-funded and the
  ads render in the TUI; free-mode admission is allowlisted to the official
  clients. A run driven by a third-party harness with the device token was
  refused, *"warning, then ban"*.
- The request is already filed twice: `CodebuffAI/freebuff#947` (open since
  2026-08-06, no maintainer reply) and `#1322` (closed by the stale bot, which
  said closing was "not a verdict"). Another issue would be a duplicate.
- The only movement is *inside* the official binary: `#1477` accepts an initial
  prompt argument and is *"deliberately not a headless mode"*; `#1611` adds
  `freebuff --acp`, serving the Agent Client Protocol over stdio. Both were open
  and unmerged on that date.

What that means here:

- The `.agent-result` protocol and the pane markers are the design, not a
  workaround to be deleted once headless lands.
- If `#1477` lands, `start` can pass the brief as an argument instead of waiting
  for raw input and typing it. That removes the most fragile step and changes
  nothing else.
- If `#1611` lands, an ACP client could drive the official binary with no pane
  at all; this tool would then be about parallel worktrees rather than session
  lifetime.

Until then, do not file another upstream one-shot request: it duplicates
`#947`, and the part that will not change on request is the admission rule
that keeps third-party harnesses out.
