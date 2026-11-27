# Machine-readable output

`sessions --json`, `status NAME --json` and `hours --json` emit the same data
as the table and the `key=value` lines, for a GUI, a dashboard or a script. The human output is
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
    "idle_seconds": null,
    "finished": false,
    "watcher": "pid:123",
    "wake_lock": "acquired",
    "worktree": "yes",
    "result": "blocked",
    "branch": "test/999",
    "pr": null,
    "hours": {
      "value": null,
      "age_seconds": null,
      "source": null
    }
  }
]
```

The `hours` object is the account usage the TUI draws, in all three values the
human views show: `value` is the `N/M` string, `source` is `panel` when the
reading came from the hours overlay and `footer` when it came from the rest of
the pane, and `age_seconds` is `0` for a reading made this run. When neither
the pane nor `.supervisor-hours` has a fraction, all three are `null` and the
human view says `-`; a ledger reading keeps its `source` and reports how old
it is, so a stale number is never passed off as current. Every reading is
appended to `.supervisor-hours` as
`ts=<epoch> hours=N/M source=panel|footer session=fb-X`.

`status NAME --json` is one object with the same fields plus the detail view's:
`running` and `dirty` as booleans, `input` (`raw|canonical|unknown`),
`session_state`, `turn_state`, `turn_outcome`, `commit`, `wake_lock`, the
`hours` object, the `result_*` keys from `.agent-result`, the pane tail as a
`pane` string, and the classifier's decision as the `evidence` object
documented below.

`turn_state` is the turn log's verdict (`working`, `finished`, `failed` or
`unknown`) and `turn_outcome` its `outputType` (`lastMessage` or `error`).
They are additive and do not change `session_state` on their own: `null` when
there is no chat directory to read, `unknown` when the directory exists but
holds no complete start/end pair. `--source log` makes `session_state` come
from the same pair (a finished turn is `idle`; `done` stays the result file's
word), and `--source auto` uses the log when it has a verdict and otherwise
falls back to the pane. `--explain` names the source, the rule and the pair it
read.

`hours NAME --json` is one object with the human line's fields: `hours` is
the `N/M` figure read from the pane, `session` the live session it came from,
`age` the seconds since the pane last changed and `source` either `panel` or
`footer`. A value the tool could not read is `null` and the command exits 2:
with no live session all four are null, and a live pane that shows no figure
has `hours` and `source` null but keeps `session` and `age`.

```json
{"hours":"10/17","session":"fb-103","age":42,"source":"footer"}
```

`status --explain` prints the classification decision line by line: the rule
that won, the line it matched, every marker that was checked, the window's line
count and hash, how many consecutive scans agreed, and the pane the rule read.

The same block is in `status --json` as an additive `evidence` object:

```json
"evidence": {
  "source": "pane",
  "rule": "no-rule-matched",
  "matched": null,
  "window_lines": 40,
  "window_sha256": "9f2c...",
  "stable_scans": 2
}
```

`source` names what produced the verdict: `pane` (a pane rule or the session
check), `log` (the turn log), `result-file` or `refusal`.

`rule` is one of `recorded-refusal`, `result-file`, `refusal-prose`,
`busy-marker`, `resting-prompt`, `protected-window`, `no-rule-matched`,
`unstable-window`, `no-session`, and for the turn log `turn-started`,
`turn-finished`, `turn-failed`, `no-turn-events` (a log with no complete
pair) and `no-turn-log` (no chat directory or no `log.jsonl`). `matched` is
the first matching line, cut to 200 characters. `unstable-window` keeps the
old safe `working` answer for a pane that changed between the two scans
without matching a rule; it is rechecked on the next poll rather than reported
as `unknown`.

A missing value is `null` rather than the table's `-`: `idle_seconds` when the
session is not running or its state is terminal (`done`, `stopped`, `blocked`,
`failed`) — a finished run has no idle time, so a done card cannot read `idle
5495s` — `result` with no `.agent-result`, `branch` and `pr` for a session with
no worktree, `watcher` with no autostop recorded, `wake_lock` when the run did
not ask for one, and `pane` when no session is running. The `hours` values are
`null` only when neither the pane nor the ledger has a reading; `age_seconds`
is `0` for a live read and the ledger's age otherwise. `wake_lock` is the
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
