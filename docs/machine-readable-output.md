# Machine-readable output

`sessions --json` and `status NAME --json` emit the same data as the table and
the `key=value` lines, for a GUI, a dashboard or a script. The human output is
unchanged: `--json` is additive. There is no `jq` and no new dependency; the
JSON is built in bash with a real string escaper, so a pane's tabs, newlines
and the CR tmux leaves behind arrive as `\t`, `\n` and `\r` instead of raw
bytes, and the rest of the control range becomes `\u00XX`.

`sessions --json` is an array of objects in the table's order, `[]` when there
is nothing to report. `state` is the table's STATE column: the live session
state when it is running, the result state when it has stopped, so `state` can
read `done` while `result` reads `blocked` — RESULT is what the agent wrote, not
what the pane is doing.

```json
[
  {
    "name": "test-999",
    "state": "done",
    "source": "pane",
    "idle_seconds": null,
    "finished": false,
    "watcher": "pid:123",
    "wake_lock": "acquired",
    "worktree": "yes",
    "result": "blocked",
    "branch": "test/999",
    "pr": null
  }
]
```

`status NAME --json` is one object with the same fields plus the detail view's:
`running` and `dirty` as booleans, `input` (`raw|canonical|unknown`),
`session_state`, `commit`, `wake_lock`, the `result_*` keys from
`.agent-result`, the pane tail as a `pane` string, and the classifier's
decision as the `evidence` object documented below.

`--source pane|concord|auto` selects where `session_state` comes from. The
Concord fields are additive: `concord_status` is the raw status the agent
reported in `.concord/WORK_STATE.json`, `concord_task` its task id, and
`concord_reason` is `task` when the file produced a verdict or the reason it
did not (`missing`, `corrupt`, `no-task`, `unknown-status`). All three are
`null` on the default pane source. The result file and a recorded refusal
outrank every source. `state` is still the result file's/placeholder value,
not the selected source's state.

`status --explain` prints the classification decision line by line: the rule
that won, the line it matched, every marker that was checked, the window's line
count and hash, how many consecutive scans agreed, and the pane the rule read.

The same block is in `status --json` as an additive `evidence` object:

```json
"evidence": {
  "source": "pane",
  "rule": "no-rule-matched",
  "matched": null,
  "loser": null,
  "loser_state": null,
  "window_lines": 40,
  "window_sha256": "9f2c...",
  "stable_scans": 2
}
```

`source` names what produced the verdict: `pane` (`pane` and `no-session`),
`concord` (a Concord task), `result-file` or `refusal`. When both a live pane
and Concord have a verdict and disagree, `loser` names the one that lost and
`loser_state` its verdict; they are `null` when there is no disagreement or
only one source.

`rule` is one of `recorded-refusal`, `result-file`, `refusal-prose`,
`busy-marker`, `resting-prompt`, `protected-window`, `no-rule-matched`,
`unstable-window`, `no-session`, and for the Concord source `concord-task`,
`concord-missing`, `concord-corrupt`, `concord-no-task` and
`concord-unknown-status`. `matched` is the first matching line or the Concord
task's status line, cut to 200 characters. `unstable-window` keeps the old
safe `working` answer for a pane that changed between the two scans without
matching a rule; it is rechecked on the next poll rather than reported as
`unknown`.

The Concord map is exactly the status the agent reported: `active`,
`assigned` and `handoff_offered` are `working`; `blocked` is `blocked`;
`review_ready`, `handed_off`, `complete` and `closed` are `done`. A status
outside that set, including `proposed`, is `unknown` with the raw value in
`concord_status`; `auto` then falls back to the pane. Concord has no `failed`
or `refused` status, so those remain the result file's and the refusal file's
words.

A missing value is `null` rather than the table's `-`: `idle_seconds` when the
session is not running or its state is terminal (`done`, `stopped`, `blocked`,
`failed`) — a finished run has no idle time, so a done card cannot read `idle
5495s` — `result` with no `.agent-result`, `branch` and `pr` for a session with
no worktree, `watcher` with no autostop recorded, `wake_lock` when the run did
not ask for one, and `pane` when no session is running. `wake_lock` is the
value `start` recorded (`acquired`, `unavailable` or `failed`), not a live
status: `termux-wake-lock` has no query, and the lock is never released by the
tool. Idle time comes back when the session is resumed and is no longer
terminal. `finished` is `true` for a session that is still running but whose
run is over — exactly the ones holding a vendor slot — and `false` otherwise,
including for a session that has already stopped.
`status` keeps `state` identical to the human
`state=` line (`unknown` when there is no result file) and adds
`result_state`, which is `null` in that case, so a consumer can tell "nothing
written yet" from "unusable state". `pr` in `sessions` is the row's PR URL;
in `status` it is an array of `{"number", "url", "title"}`, empty when the
branch has no open PR and `null` with `--no-gh` or no `gh`.
