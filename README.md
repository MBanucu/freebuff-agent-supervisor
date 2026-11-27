# Freebuff agent supervisor

Run one Freebuff agent per issue in its own git worktree and tmux session.

This was extracted from `wireless-adb-keeper`, where it ran the #100/#101/#102
agents in parallel. The tool is independent of that project: run it from any
git checkout, or point it at one with `--root`.

## Contents

- [What it does](#what-it-does)
- [Requirements](#requirements)
- [Install](#install)
- [Usage](#usage)
- [Completion](#completion)
- [Inspect and control](#inspect-and-control)
- [Machine-readable output](#machine-readable-output)
- [Static snapshot and browser GUI](#static-snapshot-and-browser-gui)
- [Threat model and deployment](#threat-model-and-deployment)
- [The 180x55 rule](#the-180x55-rule)
- [Vendor policy](#vendor-policy)
- [Safety](#safety)
- [Limitations](#limitations)
- [Upstream](#upstream)
- [Contributing](#contributing)

## What it does

1. creates `.worktrees/<name>` on a new branch from a base ref;
2. writes the brief to `.task.md` in that worktree;
3. starts Freebuff in a detached tmux session `fb-<name>` at **180x55**;
4. waits until the TUI accepts raw input, sends the "read `.task.md`" prompt,
   and requires proof that the turn began (not just that Enter was sent);
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
- GNU `stty` for the raw-mode check. A `PATH` that prefers toybox's `stty`
  (no `-F`) can be overridden with `FREEBUFF_STTY`.
- `gh` authenticated for the PR column and for the generated brief. The tool
  still works without it with `--title`/`--url` or `--no-gh`.
- `python3` is optional and used only by `gui --serve`; every other command
  works without it.
- `ttyd` is optional and used only by `gui --serve --ttyd` (or
  `FREEBUFF_TTYD`); without it the dashboard simply has no terminal links.

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

`--prompt TEXT` replaces the message typed into the TUI; the brief itself still
comes from `.task.md`. The default message names the session, its branch, its
worktree path and the issue number, so no two sessions receive byte-identical
text.

Every sent brief is hashed and appended to `.supervisor-briefs.jsonl` in the
repository root, which `start` also adds to `.git/info/exclude`. The last 20
hashes are kept: before a worktree is created, `start` refuses text whose hash
is still in that window and names the earlier session, time and hash. That is a
hard error with no keystroke sent, not a retry. `--prompt` text is hashed too,
so passing the same literal prompt to two sessions fails the second.

With `--max-sessions N` for N > 1, `start` waits a random 0–2N seconds before
typing, so a burst of launches does not reach the TUI within the same second.
`FREEBUFF_START_JITTER` overrides the bound (`0` disables the wait).

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
is gone. `start` also appends `autostop=pid:<PID>` to that log before it
returns, which is what `sessions` and `status` read for the WATCHER field.
Where `setsid` is available the watcher runs in its own session, so it
survives the caller's process group being torn down (a closed terminal, a
finished CI step). Without `setsid` it falls back to `nohup`: that still
ignores SIGHUP, but the watcher stays in the caller's process group and can
be killed with it.

### GitHub state

A session is easier to trust when the issue says what it is doing. When `gh` is
on PATH and the repository has a remote, `start` writes
`.worktrees/<name>/.supervisor-gh` (the issue and slug — neither is recoverable
from a live pane later) and moves the issue to `status:working`, leaving one
comment naming the session, branch and worktree. Every later transition moves
the same label, so an issue carries exactly one state:

| state | set by |
| --- | --- |
| `status:working` | the launch that proved its brief |
| `status:blocked` | the watcher, when `.agent-result` says blocked |
| `status:done` | `autostop`, or `stop --graceful`, with the evidence line |
| `status:failed` | the same paths, when the result says failed |
| `status:stopped` | `stop`, or any other reason the session ended early |

The labels are created on demand. The sync is a mirror, never the authority:
every `gh` failure is swallowed, so a flaky API cannot cost a vendor slot or a
worktree, and the run's own result file still decides the outcome. `--no-gh` on
`start` and `FREEBUFF_GH_SYNC=0` turn it off; `GH_BIN` selects a different
executable.

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
`.git/info/exclude`, and is never committed. `done`, `blocked` and `failed`
are kept distinct: `session_state` reports the result file's own state, and
`watch` exits `0`, `3` or `4` respectively. All three count as finished — a
draft PR plus an explanation is a valid outcome — but only `done` is success,
so a wait contract cannot read failure as completion. A custom `--task-file`
brief must include the same instruction, otherwise only the idle signal
applies.

**The idle pane (fallback).** `watch` captures the visible pane, looks at the
bottom lines, and treats the session as idle when the input prompt is visible,
no busy marker is present, and the pane is unchanged for the window. A shell
approval prompt, rate-limit notice or the concurrent-session overlay is never
treated as idle.

The marker vocabulary, captured from 0.2.38, how the classifier orders it,
the `unknown` fallback for a pane none of them claims, and the unverified
approval chrome are in
[TUI constraints](docs/tui-constraints.md#pane-markers-and-classification).

`status` reports both views:

```
state=done                  # from .agent-result
watcher=pid:123             # autostop watcher: pid:N, dead or -
session_state=done          # live: done, blocked, failed, idle, working, refused,
                            #       unknown or missing
```

The decision trail `status --explain` prints, and the `evidence` object
`status --json` carries, are documented with the JSON in
[machine-readable output](docs/machine-readable-output.md).

## Inspect and control

```bash
spawn-freebuff-agent list
spawn-freebuff-agent sessions
spawn-freebuff-agent sessions --json
spawn-freebuff-agent gui --snapshot /tmp/agents.html --watch 5
spawn-freebuff-agent status 103-example --lines 40
spawn-freebuff-agent status 103-example --no-gh
spawn-freebuff-agent status 103-example --json
spawn-freebuff-agent status 103-example --explain
spawn-freebuff-agent attach 103-example   # detach with Ctrl-b d
spawn-freebuff-agent send 103-example "Also run the new test"
spawn-freebuff-agent watch 103-example --idle-seconds 120 --poll 5
spawn-freebuff-agent autostop 103-example
spawn-freebuff-agent stop 103-example            # hard kill
spawn-freebuff-agent stop 103-example --graceful # end the turn first
spawn-freebuff-agent gc --dry-run
```

`watch` prints
`state=working|idle|done|blocked|failed|refused|unknown|missing`, and exits
`0` when the result file says `done` or the pane has been idle past the
window, `1` on `--timeout`, `2` when the session is gone, `3` when the result
file says `blocked` and `4` when it says `failed`. It never stops anything.
`autostop` is `watch` followed by a stop and an evidence record; a `done`,
`blocked` or `failed` result is stopped and the exit status is watch's (0, 3
or 4). `start --auto-stop` runs it detached.

`list` prints the branch, session, running flag, live state and idle time.
`status` prints the result state, the autostop `watcher`, `session_state`, idle
seconds, the pane tail, the last commit, whether the worktree is dirty, and any
open PR for the branch. `--window N` sets the scrollback the classifier reads
(default 40) and `--explain` adds the decision trail described in
[machine-readable output](docs/machine-readable-output.md).

`sessions` is the inventory: one row per `fb-*` session **and** per worktree,
with `WORKTREE yes|missing`, the attached `autostop` watcher (`pid:N`, `dead`
or `-`; the pid is the one `start --auto-stop` wrote to
`.supervisor.log`), the result state, the branch and the open PR. It starts from
`tmux list-sessions`, so a session with no worktree appears there instead of
only being found when `gc --all` kills it; `list` also names such orphans.
`--no-gh` skips the PR column. The last line counts what was listed —
`sessions=`, `running=`, `worktrees=`, `orphans=` and `finished=`, the live
sessions whose run is already over. Freebuff counts live TUIs against its
concurrent-session limit, not runs, so a `done` session still holds a slot
until `gc` stops it. A `start` refused by that overlay names them
(`holding_slot=a,b`) and prints the command that frees them, instead of leaving
the next step to guesswork. The hours overlay is refused the same way, as
`refused=hours` with `hours=N/M` when the panel shows the account's usage and
a `hint=` naming both ways out: free finished sessions with `gc`, or wait for
the daily refill. Neither overlay is waited out as a submit timeout.

`stop` is a hard kill. `stop --graceful` sends `Escape` to end the turn, waits
up to `--wait` seconds (default 20) for the pane to reach `done`, `idle` or
`refused`, then stops and appends `pane_state=`, `interrupted=` and the wait
to `.supervisor.log`. If the pane is still `working` when the window expires
it stops nothing and exits 1, so a kill cannot land between an edit and its
commit by accident.

`gc` stops sessions that are `done`, `blocked` or `failed`, stuck on the
concurrent-session overlay, idle for more than `--idle-hours` (default 12), or
— with `--all` — `fb-*` sessions whose worktree no longer exists. Busy, approval and `unknown` panes
are skipped with a reason, and `--dry-run` only reports. `gc` never removes worktrees or
branches; it prints the cleanup commands instead:

```bash
git worktree remove .worktrees/103-example
git branch -d issue/103-example
```

A session whose run is over is still a live TUI to the vendor, so it keeps
holding a concurrent-session slot until something stops it. `sessions` counts
these as `finished=`, and `gc` is the command that frees them: their result is
already recorded, so nothing is lost by stopping them.

`stop` only kills the tmux session; the worktree and branch remain.

## Machine-readable output

`sessions --json` and `status NAME --json` emit the table and the `key=value`
lines as JSON, for a GUI, a dashboard or a script. The human output is
unchanged and the JSON is built in bash without `jq`. The shapes, the `null`
rules for a missing value and the classifier's `evidence` object are in
[machine-readable output](docs/machine-readable-output.md).

## Static snapshot and browser GUI

`gui --snapshot FILE [--watch N]` writes one self-contained, read-only HTML
page from `sessions --json` — no server, no network and no external assets, so
it works on a phone over `file://`. `gui --serve` serves the same page over
HTTP from python3's standard library, with a token on every route, optional
forms and an optional ttyd terminal per card; the CLI stays the only source of
state. Headers, the nonce and `Origin` rules, ttyd and the routes are in
[static snapshot and browser GUI](docs/browser-gui.md).

## Threat model and deployment

The server is one shared secret in front of an inventory and three actions on
agents that each have a shell, bound to loopback by default. [The threat
model](docs/threat-model.md) covers what that protects and what it does not —
the token is not encryption and leaks through URLs, a `0.0.0.0` bind exposes
every pane, the response headers and the CSP, Host validation and DNS
rebinding — and how to put TLS and auth in a proxy in front.

## The 180x55 rule

At 120x40 the Freebuff TUI stays in canonical mode and silently ignores the
prompt, so `start` waits for raw input and the `Enter a coding task` line
before sending, then requires proof that a turn began. The readiness
predicate, the submission proof and the capacity pre-flight are in
[TUI constraints](docs/tui-constraints.md).

## Vendor policy

Freebuff polices scripted or automated use and counts a strike against the
account for a repeated message. The tool makes every stock brief unique by
construction, keeps a ledger of sent hashes, jitters launches and records a
refused send instead of retrying it; that avoids tripping the filter by
accident and does not make automation permissible. See [vendor
policy](docs/vendor-policy.md).

## Safety

- The tool writes only under `.worktrees/` in the target repository, plus
  `.supervisor-briefs.jsonl` in its root (the last 20 sent-brief hashes, plus
  any refused hash) and `.git/info/exclude` entries for `.worktrees/`,
  `.task.md`, `.agent-result`, `.supervisor.log`, `.supervisor-briefs.jsonl`
  and `local.properties`. A refusal also writes
  `.worktrees/<name>/.refusal`, which `stop` removes.
- A running agent uses its normal shell approvals. Do not attach and type while
  it is working; use `send` for a deliberate follow-up.
- Auto-stop and `gc` only kill `fb-<name>`, after appending the pane tail,
  commit, dirty flag and PR to `.worktrees/<name>/.supervisor.log`.
- `stop`, auto-stop and `gc` leave the branch and worktree in place on purpose.

## Limitations

This is a TUI supervisor, not a headless API: status is a pane capture and
the markers are tied to the Freebuff release, and a session throttled
mid-run reads as `idle`. What the deviceless suite covers, and the rest of
the known limits, are in [limitations](docs/tui-constraints.md#limitations).

## Upstream

Freebuff has no one-shot or headless mode and none is planned: the docs state
it, the requests for one are already filed, and the only movement is inside
the official binary. The `.agent-result` protocol and the pane markers are the
design, not a workaround. The evidence, and what each upstream patch would
change here, is in the [upstream
note](docs/tui-constraints.md#upstream-expect-the-tui-to-stay-the-only-mode).

## Contributing

Before changing anything, read [`AGENTS.md`](AGENTS.md) for the rules and
[`docs/development.md`](docs/development.md) for the file map, the recipes for
adding a subcommand or a check, and how to read a failing run.

`main` is protected by the ruleset `main: pull requests only`: a pull request
is required, with zero required approvals so a solo maintainer can still
self-merge. Deletion and non-fast-forward pushes are blocked, and the ruleset
has no bypass actors — the maintainer is subject to it too. Work therefore
arrives as a branch plus a PR, not as a direct push to `main`.
