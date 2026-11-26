# Freebuff agent supervisor

Run one Freebuff agent per issue in its own git worktree and tmux session.

This was extracted from `wireless-adb-keeper`, where it ran the #100/#101/#102
agents in parallel. The tool is independent of that project: run it from any
git checkout, or point it at one with `--root`.

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

Markers, captured from 0.2.38:

- idle: `▍Enter a coding task or / for commands`
- busy: `thinking...` / `working...` with a `■ Esc` hint, plus `esc to
  interrupt` and the spinner glyphs from other builds
- busy while a turn is in flight: `Add to the current task (/ for commands)` —
  no idle marker, so it is never mistaken for idle
- refused: the concurrent-session overlay (`concurrent-session limit`,
  `Take over to stop another session`) and the vendor's anti-automation answer
  (`Scripted or automated use`, `sent over and over`, `strike N today`, an
  account budget line). That answer is turn text above the resting prompt, so
  the refusal vocabulary is matched across 40 lines of scrollback, not only the
  12-line chrome window. A refusal is recorded in
  `.worktrees/<name>/.refusal` and `.supervisor.log`; `status` keeps reporting
  `refused` after the sentence scrolls away, until `stop` clears it. Because
  this is prose matching, a custom `--prompt` that quotes the refusal
  vocabulary can itself look like a refusal; the stock brief does not contain
  those phrases.
- protected: the approval/rate-limit strings are only consulted when the
  resting prompt is absent

The order of those checks matters. `session_state` reads a recorded refusal,
then the result file, then the refusal vocabulary across the window, then the
busy markers, then the resting prompt, and only then the protected strings;
when none of them matches it reports `unknown`. The resting prompt outranks them because
the startup banner `Can't reach Freebuff's servers. Retrying…` lands inside the
same 12-line window: while it was checked first, a finished session carrying
that banner reported `working` forever and was never reaped.

A pane none of those rules claims is `unknown`, not `working`. The old
fallback made new vendor chrome indistinguishable from a live turn: a pane the
tool could not read was reported as working forever. `unknown` is only raised
after the same normalised window is captured twice in a row — a repaint is
ignored, because ANSI, padding, separator rules and clock-like text are
stripped before the comparison — so a boot frame or a spinner mid-repaint does
not raise it. It remains the safe failure mode: `watch` waits, `gc` skips it
with `reason=unknown`, and `stop --graceful` refuses to kill it. These markers
are TUI chrome and can change between Freebuff releases; the result file does
not depend on them.

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
watcher=pid:123             # autostop watcher: pid:N, dead or -
session_state=done          # live: done, blocked, failed, idle, working, refused,
                            #       unknown or missing
```

`status --explain` prints the classification decision line by line: the rule
that won, the line it matched, every marker that was checked, the window's line
count and hash, how many consecutive scans agreed, and the pane the rule read.

The same block is in `status --json` as an additive `evidence` object:

```json
"evidence": {
  "rule": "no-rule-matched",
  "matched": null,
  "window_lines": 40,
  "window_sha256": "9f2c...",
  "stable_scans": 2
}
```

`rule` is one of `recorded-refusal`, `result-file`, `refusal-prose`,
`busy-marker`, `resting-prompt`, `protected-window`, `no-rule-matched`,
`unstable-window`, `no-session`. `matched` is the first matching line, cut to
200 characters. `unstable-window` keeps the old safe `working` answer for a pane
that changed between the two scans without matching a rule; it is rechecked on
the next poll rather than reported as `unknown`.

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
(default 40) and `--explain` adds the decision trail described under
completion.

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
the next step to guesswork.

### Machine-readable output

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
    "idle_seconds": null,
    "finished": false,
    "watcher": "pid:123",
    "worktree": "yes",
    "result": "blocked",
    "branch": "test/999",
    "pr": null
  }
]
```

`status NAME --json` is one object with the same fields plus the detail view's:
`running` and `dirty` as booleans, `input` (`raw|canonical|unknown`),
`session_state`, `commit`, the `result_*` keys from `.agent-result`, the pane
tail as a `pane` string, and the classifier's decision as the `evidence`
object documented under completion.

A missing value is `null` rather than the table's `-`: `idle_seconds` when the
session is not running or its state is terminal (`done`, `stopped`, `blocked`,
`failed`) — a finished run has no idle time, so a done card cannot read `idle
5495s` — `result` with no `.agent-result`, `branch` and `pr` for a session with
no worktree, `watcher` with no autostop recorded, and `pane` when no session is
running. Idle time comes back when the session is resumed and is no longer
terminal. `finished` is `true` for a session that is still running but whose
run is over — exactly the ones holding a vendor slot — and `false` otherwise,
including for a session that has already stopped.
`status` keeps `state` identical to the human
`state=` line (`unknown` when there is no result file) and adds
`result_state`, which is `null` in that case, so a consumer can tell "nothing
written yet" from "unusable state". `pr` in `sessions` is the row's PR URL;
in `status` it is an array of `{"number", "url", "title"}`, empty when the
branch has no open PR and `null` with `--no-gh` or no `gh`.

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

## Static snapshot

`gui --snapshot FILE [--watch N]` writes one self-contained HTML page from
`sessions --json`: one card per session with name, state, idle time (only while
the session can still take a turn), watcher, worktree, result, branch, PR, and
— for a session with a worktree — the
commit and the result file's `tests` line. A done session is green, a working
one amber, a failed or refused one red, and a session with no worktree carries
a `no worktree` tag.

```bash
spawn-freebuff-agent gui --snapshot /tmp/agents.html
spawn-freebuff-agent gui --snapshot /tmp/agents.html --watch 5
```

There is no server, no network and no auth: the file is opened directly or
served by any static host, so it works on a phone and nothing listens to be
attacked. There are no external assets — CSS is inline and there is no
script — so `file://` works offline and a strict CSP cannot break the view
(the page declares `default-src 'none'; style-src 'unsafe-inline'; img-src
data:; connect-src 'self'` — the last one only so Chrome DevTools' own
`/.well-known` probe is not blocked and does not fill the console). That
`<meta>` is all a static file can carry: a `file://` page has no headers.
`gui --serve` keeps it for the same markup and adds the framing, `nosniff` and
referrer headers a meta tag cannot express (see the threat model). `--watch N` rewrites the file every N seconds and adds
`<meta http-equiv="refresh" content="N">`, so an open browser follows along
without JavaScript. Without it, a single snapshot is written and the command
exits.

An empty repository renders `no sessions` instead of an empty table. Every
rendered value is HTML-escaped, because branch names, PR URLs, commit subjects
and the `tests` line are arbitrary text. The page is read-only: it offers no
buttons that only pretend to act. `gui --snapshot` never receives a form
nonce, so a static file has no forms at all; only `gui --serve` adds them (see
below), because only a server can check the nonce back.

## Browser GUI

`gui --serve` serves that page over HTTP from python3's standard library, with
no third-party packages. `GET /` runs the same `gui --snapshot` renderer into a
temporary file, so the server owns no second markup, and `/api/sessions` is
`sessions --json` verbatim — the CLI stays the only source of state.

```bash
spawn-freebuff-agent gui --serve                    # http://127.0.0.1:7788
spawn-freebuff-agent gui --serve --port 8080 --token "$TOKEN"
spawn-freebuff-agent gui --serve --read-only
spawn-freebuff-agent gui --serve --ttyd             # terminal link per card
```

- `GET /` renders one card per session, including `worktree=missing` orphans.
- `GET /tty/<name>` redirects to a ttyd viewer for that session, with `--ttyd`.
- `GET /api/sessions` returns `sessions --json` verbatim.
- `GET /api/session/<name>/pane` returns `status NAME --json`, or 404 when the
  name has no worktree.
- `POST /api/session/<name>/stop[?graceful=1]` runs `stop NAME`, or
  `stop NAME --graceful`. A **cookie-authenticated form POST** is answered
  with a confirmation page and changes nothing; the page's confirm form posts
  `?confirm=1` and runs the stop, then `303` to `/`. The first POST is the
  stray-click guard: clicking a card's Stop cannot end a live session.
- `POST /api/session/<name>/send` runs `send NAME TEXT`, with the text taken
  from a JSON body `{"text": "..."}` and never from the URL.
- `POST /api/gc[?dry=1]` runs `gc`, or `gc --dry-run`.
- Codes: 401 for a missing or wrong token, 421 for a `Host` this server does
  not answer for (checked before auth), 400 for a name that fails
  `^[A-Za-z0-9_-]+$` or a body that is not JSON, 404 for an unknown session
  (no worktree, the pane route's rule), 403 in read-only mode, for a missing or
  wrong form nonce, or for a foreign `Origin`; 409 when the CLI refuses; 413
  for a body over 64 KiB; 303 after a successful form action.

### Forms, the nonce and Origin

`GET /` renders the actions as plain `<form method="post">` elements, so the
page works with JavaScript disabled and is testable with curl:

- a `gc --dry-run` form above the cards, only when something is live;
- `Stop` and `Stop (graceful)` on a running session's card, but not on one
  whose state is already terminal (`done`, `stopped`, `failed`, `blocked`).

Every form carries a hidden `nonce` field holding a per-server random
`form_nonce` generated at startup. A POST that authenticated with the cookie
must present it, compared with `hmac.compare_digest`; a missing or wrong value
is `403`, not a silent no-op. A POST whose `Origin` header is present and does
not match the request's `Host` is also `403`, because two services on
`127.0.0.1` are same-site for a cookie (the port is not part of the site) and
`SameSite=Strict` therefore does not separate them.

A **bearer-token POST without a nonce still works**: a caller that already
read the secret keeps the `202` behavior from #22, which is what curl and the
CLI tests use. The nonce and Origin checks are for the cookie path only.

A successful form action **redirects, never re-renders**: `303 See Other` to
`/`, so a refresh is a GET and cannot replay the stop. The gc report cannot fit
in a redirect body, so `gc --dry-run` stashes its output under a one-shot key
and redirects to `/?gc=<key>`; that GET shows it once, and a refresh shows the
plain dashboard. `--read-only` renders a page with zero `<form>` elements and
still answers every POST `403`, so a reader is never offered a button whose
only outcome is a refusal.

### Live terminal through ttyd

`gui --serve --ttyd` adds a `terminal` link to every session card that has a
worktree. Following it is `GET /tty/<name>`, which starts one ttyd for that
session on demand and redirects the browser to it:

```
ttyd -p PORT -i 127.0.0.1 -c fb:TOKEN -o tmux attach -t fb-<name>
```

- **Read-only by default.** ttyd is read-only unless `-W` is passed, so a
  default viewer carries no write flag at all. ttyd 1.7.x has no `-R`: it was
  removed when read-only became the default, which is why the issue that asked
  for `-R` is implemented as "no `-W`". `--interactive` adds `-W` and is the
  only way to type into an agent from a browser.
- **Loopback and authenticated.** `-i 127.0.0.1` keeps the viewer on this host
  and `-c fb:<token>` derives basic auth from the server token, so the redirect
  never points at an unauthenticated port. The browser asks once for the
  credential: user `fb`, password the GUI token.
- **One viewer per session.** A second click reuses the running ttyd instead of
  starting another, `-o` makes ttyd exit when its tab disconnects, and the
  server terminates any viewer still running when it stops (including on
  `SIGTERM`).
- **`--read-only` refuses `--interactive`** at startup with exit 2 rather than
  silently downgrading it.
- **Codes:** `302` to the viewer, `409` when `fb-<name>` is not running, `404`
  for a name with no worktree, `400` for a name that fails the same validation
  as every other route, and `503` when ttyd is missing.
- **Without ttyd** the server still starts: the dashboard renders with no
  terminal links and one line saying why, instead of returning a 500.

`FREEBUFF_TTYD` names the binary. When it is set, PATH is not consulted, so
pointing it at a path that does not exist means "no ttyd" — useful on a
machine that has one installed but should not offer it.

Maintenance caveat: ttyd's last tag is 1.7.7 (March 2024). The repository still
receives commits, but distro packages lag, so check `ttyd --version` before
relying on a packaged build. The integration is optional for exactly that
reason: without ttyd everything else behaves as before.

An action is one CLI call and nothing else: a non-form caller gets `202` with
the CLI's own `key=value` lines, a form submission gets `303` to the dashboard
(on success; the gc report travels under the one-shot key above), so there is
no second result vocabulary to keep in step. On failure it returns the CLI's
exit status and message instead — `409` for exit 1, which is a session in the
wrong state, `500` otherwise — as a page for a form caller and as text for the
API. That is what lets a
browser tell "stopped" from "still busy" after a graceful stop, rather than
reading a refusal as success. The name is validated before it reaches a path or
a subprocess, the `send` text is passed as a single argv element and never
through a shell, and the token is still required on every POST even on loopback,
so a page in another tab cannot stop an agent. `--read-only` answers these
routes `403` rather than hiding them, so a caller learns why.

The token is compared in constant time and accepted as
`Authorization: Bearer T`, as an `fb_token` cookie, or as `?token=T` on a GET
that then sets the cookie. Without `--token`, one is generated and printed
once to stderr; it is never written to a log file. The server binds
`127.0.0.1` by default and refuses a non-loopback `--host` unless `--token`
was given explicitly. Binding to `0.0.0.0` exposes the pane of every agent to
the LAN, so use it only behind a reverse proxy (Caddy, Tailscale Serve) that
terminates TLS — this server does not.

## Threat model and deployment

The server is one shared secret in front of an inventory and three actions on
agents that each have a shell. This section is what that protects, what it does
not, and how to expose it off this host without getting it wrong.

### Loopback is the default, and the only mode that is safe to leave on

`gui --serve` binds `127.0.0.1:7788` (`--port 0` picks a free port and prints
the URL). Nothing outside the machine can connect, so the network is not part
of the attack surface at all. A non-loopback `--host` exits 2 unless `--token`
was passed **explicitly**: a generated token does not count, so `--host 0.0.0.0`
typed by accident fails instead of quietly opening a dashboard to the LAN.

Loopback is still authenticated. The token is required on every route,
including `GET /`, because "local" is not the same as "yours".

### What the token protects

One secret per server, compared with `hmac.compare_digest`, accepted three
ways: `Authorization: Bearer T`, the `fb_token` cookie, or `?token=T` on a GET,
which sets the cookie. The cookie is `HttpOnly`, `SameSite=Strict` and
`Path=/`, with no `Secure` flag and no expiry, because there is no TLS and it
should die with the browser. Without `--token` the server makes 24 random bytes
(`secrets.token_urlsafe`, 32 URL-safe characters), prints it once to stderr,
and never writes it anywhere; a restart without `--token` therefore means a new
secret, and the old one is gone rather than rotatable.

Against anything that does not hold the secret, the token is the whole
difference between reading and doing nothing:

- **Read:** the session inventory, each session's pane tail, commit subject,
  dirty flag and PR — branch names, command output and whatever the agent has
  on screen.
- **Act:** `stop`, `stop --graceful`, `send TEXT` and `gc`. `send` types into
  the agent's TUI, and the agent has a shell in its worktree, so a token is
  effectively at least the agent's authority, not just a dashboard's.

There is no per-user identity, no per-session scope, no expiry and no record of
*who* acted: the log line is client address, method and path only. Every holder
has every route. `--read-only` is the only reduction and it is a flag on the
whole server (403 on POST), not a property of a token.

### What the token does not protect

- **It is not encryption.** The secret, the pane text and the `send` text are
  plain HTTP. On a LAN anyone on the path can read them and replay the token.
  There is no TLS, no HSTS and no certificate handling in this server.
- **It leaks through URLs.** The bootstrap `?token=T` is in the address bar and
  the browser history on purpose. The server logs only the path
  (`log_message` strips the query), but a reverse proxy or access log in front
  records the full request line. Treat that first URL as a secret and keep
  query strings out of proxy logs.
- **It is only as good as its storage.** `--token "$TOKEN"` puts it in shell
  history, `ps` and tmux scrollback. Prefer letting the server generate one and
  reading it from stderr.
- **It has no rate limit or lockout.** A wrong token is a 401 and nothing else,
  so guessing is bounded only by the 192-bit secret.
- **It does not make a browser page trustworthy on its own.** Cookies are
  scoped by host, not port, so another service on `127.0.0.1` is same-site for
  `fb_token` and can make the browser send an authenticated POST. The
  server-rendered forms reduce that: a cookie POST needs the page's per-server
  nonce and must not present a foreign `Origin`, so a page that never saw this
  dashboard cannot assemble a valid action. That is defence in depth, not a
  second identity: the nonce is visible to anything that can read the page
  (a token holder already reads every pane), and a caller that sends no
  `Origin` and holds a bearer token bypasses the nonce on purpose for curl
  compatibility. Treat anything else on the same host as able to read the
  dashboard if it has the token.
- **`--read-only` is not a second boundary.** It answers POST with 403 for
  everyone, which is the point, but a token holder still reads every pane.

### Response headers: framing, referrer and the CSP

The served page is interactive, so the server sends the headers a `<meta>` tag
cannot express. Every response carries them — the dashboard, `/api/*`, the
`303` after a form action, and the `401`, `403`, `404` and `421` refusals —
because a refusal is still a document a browser renders.

| Header | Value | What it stops, and what it does not |
| --- | --- | --- |
| `Content-Security-Policy` | `default-src 'none'; style-src 'unsafe-inline'; img-src data:; connect-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'` | Injected markup cannot load or run anything: no script, no object, no external style, no framing, and no injected `<base>` retargeting a form. `style-src 'unsafe-inline'` is required by the page's single inline `<style>`; there is no script, no `unsafe-inline` for script and no `unsafe-eval`. It does **not** stop a token holder — a holder can read every pane and POST every action without a browser — and it does not replace HTML-escaping: escaping is still what keeps pane text from being markup. |
| `X-Content-Type-Options` | `nosniff` | A browser may not re-interpret a JSON or text answer as HTML or script by sniffing; `Content-Type` is the only type. |
| `X-Frame-Options` | `DENY` | The older clickjacking control, for a browser that ignores `frame-ancestors`; both are sent. |
| `Referrer-Policy` | `no-referrer` | No `Referer` leaves the page. A card links to the PR on github.com, and the URL may still carry the bootstrap `?token=` when that link is clicked; without this header the full dashboard URL, secret included, would travel to a third party. |

`form-action 'self'` does not break the POST → `303` flow: the form targets
this server and the redirect is a navigation, not a second submission. The
suite asserts it on the wire. The static `--snapshot` page keeps its narrower
`<meta>` policy, because a file opened over `file://` has no headers; where
both apply the two policies agree, so the intersection changes nothing.

### Host validation and DNS rebinding

The server answers only the names it serves: `127.0.0.1`, `localhost` and
`[::1]`, each with or without a port, plus the configured `--host` and any
`--allow-host NAME` (repeatable). Anything else is `421 Misdirected Request`
and reaches no route — the check runs before the token check, so not even a
bearer caller gets an answer under a foreign name.

The reason is DNS rebinding. A page on `evil.example` can re-resolve that name
to `127.0.0.1`, and its own script then speaks to this server as a same-origin
peer; every loopback port is the same site for a cookie. The random token is
still the barrier against reading or acting, but the Host check makes the name
useless before that: no dashboard to frame, no API to probe for a difference
between 401 and 200, and no route where a later unauthenticated addition would
be reachable. It does not protect a token holder and it is not a substitute for
the token; it closes the one path where the browser, not the attacker, supplies
the authority.

An absent `Host` is allowed (HTTP/1.0 and some local clients omit it, and a
missing name is not one an attacker can choose). `--host 0.0.0.0` accepts only
the loopback names, so reaching a LAN bind by IP needs that address in
`--allow-host`. A proxy in front must pass a name the server knows: see the
deployment section.

### Why POST needs the token even on localhost

Loopback is not a trust boundary. Any local process can connect: a browser
extension, another user on a shared machine, a compromised dependency, a page
the browser is showing. Without the token those could stop an agent between an
edit and its commit, or `send` arbitrary text into a TUI that then runs it.
Requiring it makes an action deliberate, and there is no weaker path for
actions than for reads — the same check runs before every route.

### What a `0.0.0.0` bind exposes

With `--host 0.0.0.0 --token T`, every host that can route to this machine and
knows the token gets the dashboard and everything above: the pane tail of every
agent (`GET /api/session/<name>/pane`), the result files, the branches, the PR
URLs, and the ability to stop, type into and gc every session. The API is
`status NAME --json` and `sessions --json` verbatim, so nothing is filtered
out. A leaked token gets the agent's own shell in the worktree, by way of
`send`.

The transport is plaintext, the token included, and the cookie is not `Secure`,
so the token is readable and replayable by anyone on the path. The dashboard is
identical to the one on loopback; there is no separate "LAN mode" with extra
checks.

The ttyd terminal link does not widen this: the redirect always targets
`http://127.0.0.1:<port>` and ttyd binds loopback, so from another machine the
link resolves against the *browser's* own host and does not reach yours. Behind
a proxy it is simply a broken link unless the proxy also maps the ttyd ports.

### Deployment: TLS and auth belong to a proxy in front

This server does not terminate TLS, by design; a reverse proxy does, on the
same host, with the server left on loopback so the only plaintext hop is a
local one.

Caddy, on the machine running the dashboard:

```caddyfile
agents.example.com {
    reverse_proxy 127.0.0.1:7788
}
```

`caddy` gets a certificate for its own name and forwards `Authorization` and
`Cookie` unchanged, so the token is still checked by this server, now over TLS.
Caddy passes the incoming `Host` through unmodified, so the server has to be
told that name or the request is a 421:

```bash
spawn-freebuff-agent gui --serve --allow-host agents.example.com
```

`--allow-host` is repeatable. The form's `Origin` check keeps working, because
`Origin` and `Host` are then the same name. nginx is the same idea, with
`proxy_pass http://127.0.0.1:7788;`, `proxy_set_header Host $http_host;` (its
default is the upstream's address) and the matching `--allow-host`. Tailscale
Serve (`tailscale serve --bg 7788` with the default loopback bind) gives the
dashboard an HTTPS name inside the tailnet — pass that name to `--allow-host` —
and tailnet membership then decides who reaches it: a network control, not a
replacement for the token.

Two things a proxy does not fix. The server reads no `X-Forwarded-*` header, so
it cannot log the real client address or trust a proxy-injected identity; and
the `?token=` bootstrap URL still lands in the proxy's access log unless you
scrub query strings there. After the first request the `fb_token` cookie
carries the secret, so a stricter option is to load the page once and then
remove the token from history.

If you do bind `--host 0.0.0.0` directly instead, none of that applies: it is
plaintext on every interface, authenticated only by the token. Use it on a
single-user machine you already trust, and not on a shared network.

**What was tested.** The deviceless suite drives `gui --serve` on loopback with
curl: 401 without a token, the token as header, query and cookie, the POST
actions, `--read-only` 403 and a read-only page with no forms, the cookie path
(`403` without a nonce, `403` with a nonce and a foreign `Origin`, the
confirmation page that changes nothing, the confirm POST's `303` to `/`, and
the card reading `stopped` afterwards), the gc `303`/one-shot report, the
bearer POST without a nonce still answering `202`, the refusal of
`--host 0.0.0.0` without an explicit `--token`, the ttyd redirect, the four
security headers on `200`, `401`, `403`, `404`, `421` and `303`, a foreign
`Host` answered `421` even without a token, the loopback names and
`--allow-host` accepted, and `form-action 'self'` with the POST → `303` flow.
**Not tested:** TLS or any reverse proxy,
Tailscale, a real LAN client, and the same-site cookie case above. Those
paragraphs describe the source and the operator's job, not a tested path;
confirm them with your own proxy before relying on them.

## The 180x55 rule

The size is not cosmetic. At 120x40 the Freebuff TUI stays in canonical mode
and silently ignores the prompt. `start` waits for `-icanon` and the
`Enter a coding task` line before sending anything, and fails with the last
pane lines if the TUI never becomes ready.

The wait is a predicate with a deadline, not a fixed count: `start` re-checks
every `--ready-poll` seconds (default 0.5) until `--ready-timeout` seconds
(default 120) have passed. The old gate was 90 polls — a fixed 45 seconds —
and a cold first launch in a fresh worktree (the banner, the trust prompt, the
session list scan) outran it, so `start` killed a pane that was about to become
ready. A warm pane still returns on the first check and pays no poll. Both
values are in `start --help` and in the `--dry-run` plan (`ready_timeout=120s
ready_poll=0.5s`).

While it waits, `start` notes `waiting-for-ready=yes elapsed=Ns` every ten
polls, and records the outcome in `.worktrees/<name>/.supervisor.log`:
`ready=yes` or `ready=timeout`, each with the elapsed seconds, the timeout and
the poll interval. A pane that never becomes ready can never accept the
brief, so `start` prints the last pane lines, stops that session, and fails in
a message naming the `--ready-timeout` that was used, leaving the worktree and
branch in place. The elapsed time and pane tail are what distinguishes a slow
cold start from a hung TUI; raise `--ready-timeout` for the former. The concurrent-session overlay is a refusal instead: no keys are typed
(its Enter would take over another live session), `start` prints `refused=yes`
with the sentence and exits non-zero, and the worktree is kept.

**A ready pane can still swallow the Enter.** That failure looks healthy: the
composer clears, the session rests at the idle prompt, the worktree is clean
and `session_state` says `idle`, so the old `start` printed `started=yes` for a
run that never began. The keystroke is therefore not proof. After typing,
`start` captures the pane every `--ready-poll` seconds until
`--submit-timeout` seconds (default 20) have passed, and requires both:

- the input line has cleared — it shows `Enter a coding task` or `Add to the
  current task`, not the brief still waiting for Enter; and
- a turn is in flight (`thinking...` / `working...` / the mid-turn composer)
  **or** the `Chat:` title changed from the one captured before the send.

It is a predicate with a deadline, so an accepted send is reported on the
first check — `sent=yes submit_proof=turn-began elapsed=0.0s` — and no fixed
sleep is paid. A changed title is `submit_proof=chat-title`: the client took
the brief and named the chat before the busy chrome was drawn.

A brief that never proves submission prints `sent=no`,
`submit_proof=none`, `resent=no` and the pane lines the check read, records
`submit=no elapsed=...` in `.supervisor.log`, stops the session and exits
non-zero with the worktree and branch kept, like every other failed launch.
It is never retyped: an automatic resend is how a duplicate turn starts, and a
repeated identical message is what the vendor's scripted-use filter counts as
a strike. The brief's hash reaches the ledger only once the send is proven, so
a swallowed brief — which nobody saw — does not block a deliberate retry with
the same text.

Because every session shares one account, `start` checks capacity before it
spends a worktree: `--max-sessions N` refuses to start while N `fb-*` sessions
are live, and `--wait-slot [SECONDS]` (default 300, requires
`--max-sessions`) polls until one goes away. A refused `start` creates nothing at all.

## Vendor policy: scripted use

Freebuff polices scripted or automated use. Its filter refuses a message that
repeats one already sent — "It breaks the usage policy (Scripted or automated
use): it is the same message sent over and over" — and counts a strike against
the account; strikes reset at midnight with the daily hours. The refused
session is released, so the run produces nothing.

This tool drives an interactive client with a shell-backed account, several
sessions at a time, and types a brief into each. It can therefore generate
exactly the pattern that filter looks for. The mitigation below does not make
that automation permissible, and it does not override the vendor's decision:
it only stops the tool from tripping the filter by accident, which is a bug in
this repository, not a policy argument.

- **Unique by construction.** The stock brief names the session, branch,
  worktree and issue, so two issues never send the same bytes. There is no
  random filler: the text carries real content instead of looking less
  scripted.
- **A ledger of what was sent.** Each send is hashed into
  `.supervisor-briefs.jsonl` (last 20 kept) and an identical hash inside that
  window is refused locally, before any keystroke and before a worktree is
  created.
- **Jittered launches.** Under a multi-slot `--max-sessions`, sends are spaced
  by a random delay instead of arriving in one second.
- **A refused send is recorded, not retried.** `start` checks the pane before
  typing (the overlay gets no keys at all) and after the send. A refusal prints
  `refused=yes` with the sentence and exits non-zero; the sentence goes to
  `.supervisor.log`, and the hash is marked `"refused": true` in the same
  ledger. Refused hashes are kept past the 20-entry window and are never sent
  again.

If Freebuff refuses a send anyway, the strike is the vendor's decision and the
account's cost; this tool cannot undo it. Do not add randomised filler or
prompt churn to get around the filter — that is the behaviour the policy
targets, and a strike is the user's risk to accept before running several
agents.

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
  transitions (including an unclassifiable pane becoming `unknown` with its
  evidence and the `--explain` dump),   autostop and `gc` decisions, the
  `sessions` inventory, graceful stop, the capacity pre-flight, the submission
  proof (an accepted turn, a changed chat title, a swallowed Enter and a brief
  left in the input line), and the server's routes, auth, actions and bind
  rules without a Freebuff session, account slot, `gh` or network.
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

## Contributing

`main` is protected by the ruleset `main: pull requests only`: a pull request
is required, with zero required approvals so a solo maintainer can still
self-merge. Deletion and non-fast-forward pushes are blocked, and the ruleset
has no bypass actors — the maintainer is subject to it too. Work therefore
arrives as a branch plus a PR, not as a direct push to `main`.
