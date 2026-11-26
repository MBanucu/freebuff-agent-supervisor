# TUI constraints: the 180x55 rule, limitations and upstream

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

## Pane markers and classification

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
