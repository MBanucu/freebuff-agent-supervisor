# Development

The map of this repository and the recipes for changing it. Read
[`AGENTS.md`](../AGENTS.md) first for the rules; this file explains where
things live and how a change lands.

Everything here is deviceless: both suites use a fake tmux and fixture panes,
so no Freebuff session, account slot, `gh` or network is needed. Neither suite
starts a real agent.

## The map

| Path | What lives there |
| --- | --- |
| `spawn-freebuff-agent` | The whole shipped tool, in one bash file: `usage()` at the top, shared helpers, one function per subcommand (`start`, `status`, `sessions`, `gui`, `stop`, ...), and the subcommand dispatch at the bottom. |
| `spawn-freebuff-agent-test.sh` | The deviceless runner. Sources `test/lib.sh`, then each area file in order, and prints `ok N checks`. |
| `test/lib.sh` | The shared harness: temporary git repo, fake tmux/stty/freebuff, pane fixtures, `check`/`contains`/`json_ok`, and the cleanup trap. |
| `test/cli-json.sh` | Area: the CLI surface, the git exclude list, `--json` output and the remaining flags. |
| `test/snapshot-gui.sh` | Area: the static HTML snapshot, its escaping and `--watch`. |
| `test/state-evidence.sh` | Area: the `.agent-result` protocol, pane classification and its evidence, `--explain`, and the terminal-idle rule. |
| `test/lifecycle-sessions.sh` | Area: autostop, `gc`, the `sessions` inventory, graceful stop and the capacity pre-flight. |
| `test/brief-refusals.sh` | Area: the brief-hash ledger and the vendor refusal vocabulary and state. |
| `test/readiness-submission.sh` | Area: the readiness deadline and proof that the brief was submitted. |
| `test/wait-actions.sh` | Area: `gui --serve` — the read-only server, the POST actions and the ttyd route. |
| `gui-test.sh` | The second suite: curl checks for `gui/server.py`. It reuses `test/lib.sh` and prints `ok N gui checks`. |
| `gui/server.py` | The HTTP server for `gui --serve`, python3 standard library only. It shells out to the CLI, which stays the single source of state. |
| `docs/freebuff-integration.md` | Research roadmap for MCP, hooks and completion notifications. Nothing in it is implemented. |
| `.github/workflows/deviceless.yml` | CI job `deviceless`: stubs `freebuff` on `PATH`, runs `./spawn-freebuff-agent-test.sh`. |
| `.github/workflows/gui.yml` | CI job `gui`: same stub, runs `./gui-test.sh`. |
| `README.md` | The user-facing reference: install, usage, behaviour, threat model, contributing. |

`.worktrees/` and `.supervisor-briefs.jsonl` are runtime state, explained at
the end of this file. Both are ignored; neither is committed.

## How to add a subcommand

The tool is one file, so a subcommand touches four places:

1. **The function.** Add `cmdname() { ... }` beside the related functions in
   `spawn-freebuff-agent`. Parse flags with the same `while [ $# -gt 0 ]` /
   `case` shape as its neighbours, reject unknown flags with `die`, and keep
   the output plain `key=value` lines. `--json`, when present, is additive and
   must not change the human output.
2. **The usage text.** Add a block to `usage()` inside its `cat <<'USAGE'`
   here-doc: the command line and every option, including defaults. `--help`
   is the only documentation a user sees without the README.
3. **The dispatch.** Add a case to the final `case "$cmd" in` block, for
   example `cmdname) cmdname "$@" ;;`. Existing aliases show the pattern
   (`list|ls`, `sessions|ps`); add one only when it helps.
4. **The tests and the README.** Add checks to the area file that owns the
   topic — a new CLI surface belongs in `test/cli-json.sh`, a state rule in
   `test/state-evidence.sh`. Then document the command under the matching
   README section (`Usage`, `Inspect and control`, or the behaviour section it
   belongs to).

Run both suites when you are done. A new subcommand that adds coverage raises
the check count; state the new count in the PR. If you only moved code, the
count must be unchanged.

## How to add a check

Find the area that owns the behaviour:

| Behaviour | Area file |
| --- | --- |
| CLI flags, exclude list, `--json` shape | `test/cli-json.sh` |
| Static snapshot, HTML escaping, `--watch` | `test/snapshot-gui.sh` |
| Result file, pane state, `--explain`, evidence | `test/state-evidence.sh` |
| `autostop`, `gc`, `sessions`, graceful stop, capacity | `test/lifecycle-sessions.sh` |
| Brief ledger, refusals | `test/brief-refusals.sh` |
| Readiness deadline, submission proof | `test/readiness-submission.sh` |
| `gui --serve` routes and actions | `test/wait-actions.sh` |

A check is one `check` call:

```bash
check test "$rc" -eq 0
check contains "$out" 'session_state=idle'
check json_ok "$out"
```

`check` increments the total and, on failure, prints
`FAIL <area>:<line> <command>` using its caller. `contains` is a literal
`grep -qF`; `json_ok` parses with python3 when available and otherwise checks
the JSON shape and the absence of raw tabs and CR bytes, so it still means
something on a bare phone. More helpers (`fake_session`, `fake_clear`,
`fake_add_session`, `launch_brief`) are defined in `test/lib.sh`.

To answer the common question directly: a check that `status --json` keeps its
round-trip fields goes in `test/cli-json.sh`; a check about what
`session_state` or the `evidence` object says belongs in
`test/state-evidence.sh`.

Do not create a new area file for one check. If the topic is genuinely new,
add a file with a one-line `# Area:` header, source `test/lib.sh` from it, and
add its name to the `for area in ...` list in `spawn-freebuff-agent-test.sh`
(the runner's single summary line depends on that list).

## Running checks

```bash
./spawn-freebuff-agent-test.sh   # deviceless CLI suite
./gui-test.sh                    # gui server suite
```

The CLI suite also runs one area on its own, as the runner's header documents:

```bash
. test/lib.sh && . test/state-evidence.sh
```

That is a fast loop while editing, not a gate: a standalone area prints its
`FAIL` lines but no summary, and its exit status is the last command's, not
the failed-check count. `./spawn-freebuff-agent-test.sh` is the command CI
runs and the one whose `ok N checks` line and exit status count. A few
area checks are timing-sensitive (the pane-idle waits), so a lone run can fail
where the full suite passes; rerun the full suite before believing it.

A quick syntax check that needs nothing installed:

```bash
bash -n spawn-freebuff-agent
```

`gui-test.sh` drives the server on `--port 0`, waits for the
`listening=` line instead of sleeping, sends curl requests, and kills every
server it started through the cleanup hook. It skips (with exit 0 and a
`skip gui server checks` line) when `python3` or `curl` is missing, because
the CLI keeps working without python3 and only the server needs it. On a
machine without them this is a skip, not a gui pass.

## Reading a failing run

Locally, a failed assertion prints:

```text
FAIL state-evidence.sh:24 contains ... result_pr=https://example.test/pr/1
```

The file and line are where the check is written, and the rest is the command
as it was invoked. If an unguarded command fails instead, `set -e` ends the
suite and the ERR trap in `test/lib.sh` prints:

```text
error: line 203 exited 1
```

That line number is in the area file being sourced at the time (the trap is
shared, so it does not name the file); the nearest `FAIL` line or the runner's
last area identifies it. If no `FAIL` or `error:` line appears at all, the
suite's last stderr write is the only remaining clue — that silent case is
what #32 fixed by adding the trap. When the harness is sourced by a one-liner
with no caller frame, the trap itself can end with a `BASH_LINENO[0]: unbound
variable` line; the `error: line ...` line above it is still the real one.

For CI, list recent runs and read the failed job's log:

```bash
gh run list -R MBanucu/freebuff-agent-supervisor --limit 5
gh run view <run-id> --log
gh run view <run-id> --log-failed
```

The jobs are named `deviceless` and `gui`, and both stub `freebuff` on
`PATH`; a failure in the stub setup is not a suite failure. `--log` prints the
whole run, `--log-failed` only the failed steps. Reproduce locally with the
same command the workflow runs (`./spawn-freebuff-agent-test.sh` or
`./gui-test.sh`) before changing anything.

## Fixtures and the shared harness

`test/lib.sh` is the one place for:

- the temporary git repo (`$REPO`), its initial commit and the
  `.worktrees/test-999` path (`$WT`);
- the fake tmux (`$TMP/bin/tmux`, driven by `$FAKE_DIR`), the fake `stty`
  that reports raw mode, and the stub `freebuff` that exits 0;
- the captured pane fixtures `IDLE_PANE`, `BUSY_PANE`, `REFUSED_PANE`,
  `STRIKE_PANE`, `BANNER_IDLE_PANE`, `TURN_PANE`, `SWALLOWED_PANE` and the
  rest, plus the `fake_session` / `fake_clear` / `fake_add_session` /
  `launch_brief` helpers;
- `check`, `contains`, `json_ok` and the cleanup hook that removes `$TMP`.

`gui-test.sh` sources the same file and adds only its server harness, so a
fixture change is one edit. The panes are captured from Freebuff 0.2.38; when
the TUI changes, update the fixture and say which release you captured. The
suites never exercise the real TUI — verify marker changes with one controlled
run when upgrading Freebuff.

## `.worktrees/` and `.supervisor-briefs.jsonl`

`.worktrees/<name>` is a real git worktree that `start` creates on the new
branch. The agent works there; `stop`, autostop and `gc` only kill its
`fb-<name>` tmux session and leave the worktree and branch in place. It also
holds the run evidence: `.supervisor.log` (readiness, submission, stop and
autostop transitions), and when applicable `.refusal` and `.agent-result`.
The directory is ignored by `.gitignore`; review happens through the branch
and PR, not by committing the worktree.

`.supervisor-briefs.jsonl` is the brief ledger in the repository root, also
excluded from git. `start` appends the hash of every brief it sends, keeps the
last 20, and refuses to send text whose hash is still in that window; refused
hashes are kept past the window and never sent again. It is a safety guard
against the vendor's repeated-message filter, not a cache: deleting it resets
the guard instead of fixing a refusal.
