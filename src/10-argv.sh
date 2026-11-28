# ---- argv and usage ----
# The defaults every subcommand shares, the usage text, and the predicates
# that validate an argument before anything is created.
COLS=180
ROWS=55
PROMPT='Read the file .task.md in this directory and execute it autonomously. Do not commit .task.md, .agent-result or local.properties. Follow the PR instructions in it exactly. Do not ask questions; if blocked, open a draft PR and explain.'
RESULT_FILE='.agent-result'
# Concord writes this export under the worktree's own .concord/ when an agent
# uses its work-state tools. status can read it instead of the pane (#68).
CONCORD_FILE='.concord/WORK_STATE.json'
# Written next to a worktree at launch: issue and slug, so a transition later
# (blocked, done, stopped) can label the right issue without asking the pane.
GH_STATE_FILE='.supervisor-gh'
# The vendor refuses a message identical to a recent one as scripted use and
# counts a strike, so every sent brief is hashed here before it is typed. The
# file lives in the repository root and the last BRIEF_LEDGER_KEEP hashes are
# kept: a brief stops counting as a duplicate once it has aged out of the
# window, so a retry next week is not blocked by today's run.
BRIEF_LEDGER='.supervisor-briefs.jsonl'
BRIEF_LEDGER_KEEP=20
# The pane is the only completion signal Freebuff offers. Markers are matched
# against the bottom lines of the visible pane only, so prose in the agent's
# scrollback cannot keep a finished session alive.
# Verified against Freebuff 0.2.38: a running turn shows `thinking...` /
# `working...` with a `■ Esc` hint in the bottom-right; `esc to interrupt` and
# the spinner glyphs are kept for other builds.
BUSY_RE='esc to interrupt|thinking\.\.\.|working\.\.\.|■ Esc|[◐◓◑◒]'
PROTECTED_RE='approval|approve|Allow once|Allow always|Run command|permission|rate limit|Can.t reach Freebuff'
# A refusal is not only the concurrent-session overlay. The vendor also
# answers a brief as a finished turn, above the resting prompt: "Freebuff did
# not send this message to the model ... the same message sent over and over
# ... counts as strike 1 today", usually with an account budget line. A
# session that shows that answer is not healthy and idle: the account was
# penalised. Keep the phrases specific enough that an agent discussing the
# policy in its own prose does not match them.
REFUSED_RE='Not enough hours|session limit|Take over to stop another session|did not send this message to the model|Scripted or automated use|sent over and over|automated account or site farming|counts as strike [0-9]+|strike [0-9]+ today|account budget|daily budget|budget (is )?(exhausted|exceeded|reached|remaining|left)|remaining budget|out of (daily )?hours|daily hours (refill|reset)'
# Only the overlay offers an Enter that takes over another live session, so
# send refuses to type into a pane carrying one of these strings.
REFUSAL_OVERLAY_RE='concurrent-session limit|session limit across CLI and Desktop|Take over to stop another session'
# The account's other refusal: no hours are left for the chosen model, so the
# brief cannot run until the daily refill or another model. Its Enter opens the
# model picker instead of submitting, and a wait for submission would sit out
# the whole --submit-timeout over a refusal that was already on screen.
HOURS_OVERLAY_RE='Not enough hours'
# A released session has no composer: its overlay offers Enter (retry with a
# model, which starts a new session) and Escape, so typed text goes into the
# overlay and is lost. send refuses it instead of typing (#121).
RELEASED_OVERLAY_RE='This session was released|Choose a model to start a new session'
# Freebuff's trust gate runs in the plain terminal before the TUI mounts: a
# worktree with .agents/ (or an mcp.json) prints this and waits. The resting
# prompt cannot appear while it is open, so the readiness wait must name it
# instead of spending --ready-timeout. It is a user decision about running
# repository-supplied code; start never answers it.
TRUST_PROMPT='Load and run these?'
# A refusal is written here as well as to .supervisor.log. The file is what
# keeps status at refused after the sentence has scrolled away; stop removes
# it, so a refusal lasts until the session is explicitly stopped.
REFUSAL_FILE='.refusal'
# Every hours=N/M observation appends one line here, so the last reading
# outlives the session that showed it (#108):
#   ts=<epoch> hours=N/M source=panel|footer session=fb-X
# A reading from the ledger is always shown with its age, never as current.
HOURS_LEDGER='.supervisor-hours'
# Scrollback read for an hours line: the overlay sits above the resting
# prompt, and the footer is the last line.
HOURS_WINDOW=40
# Set by hours_read: the value and source of the reading, its age in seconds
# (0 for a live read, the ledger age otherwise) and whether it was read from
# the pane this run. FRESH=0 means the value came from the ledger.
HOURS_VALUE=''
HOURS_AGE=''
HOURS_SOURCE=''
HOURS_FRESH=0
# The account's own usage (#124): one authenticated GET answers what the pane
# scrape works around, so the figure is the account's rather than a session's.
# The token is the client's default.authToken and no fingerprint field or
# cookie jar is needed. curl is read-only like gh and stays optional: without
# it the state is named and the pane is still the fallback.
ACCOUNT_URL='https://freebuff.com/api/web/freebuff-session'
ACCOUNT_TIMEOUT=5
# Set by account_read: STATE names why a read failed (unconfigured, nocurl,
# request, novalue, unauthorized) and the figures it parsed.
ACCOUNT_STATE=''
ACCOUNT_REMAINING=''
ACCOUNT_LIMIT=''
ACCOUNT_RESET=''
ACCOUNT_HOURS=''
# Turn text sits above the visible prompt, so refusal detection reads this
# many lines of scrollback rather than the 12-line chrome window.
REFUSAL_WINDOW=40
# The state monitor (#43) records a transition, never a poll, so a long run is
# a history instead of a log. The ledger sits in the repository root beside the
# other ledgers and is rotated, because a phone has no room for an unbounded
# one: at --ledger-max-bytes it is renamed to <path>.1 and a fresh file starts.
STATE_LEDGER='.state-monitor.jsonl'
# Seconds between scans. --once ignores it entirely and never sleeps.
MONITOR_INTERVAL=10
# A non-terminal state held longer than this is stuck. The flag is recorded in
# the ledger, so it fires once per run of that state and not on every poll.
MONITOR_STUCK_AFTER=1800
# More than MONITOR_FLAP_LIMIT transitions inside MONITOR_FLAP_WINDOW seconds
# usually means the pane markers disagree rather than the agent being busy.
MONITOR_FLAP_WINDOW=600
MONITOR_FLAP_LIMIT=3
# 1 MB, the default cap a phone can afford to lose to a ledger.
MONITOR_LEDGER_MAX=1048576
# No rule matching a pane used to fall through to `working`, which made new
# vendor chrome indistinguishable from a live turn. It is now `unknown`, but
# only once the same normalised window has been seen twice: a boot frame or a
# mid-repaint changes between scans and is not evidence of a new state.
UNKNOWN_RESCAN_DELAY=0.4
# Readiness gate: the TUI accepts the brief only once it is in raw mode and
# draws its resting prompt. A cold first launch in a fresh worktree pays for
# the banner, the trust prompt and the session scan, which outran the old
# fixed 45s gate, so the default deadline is generous and both values are
# per-start flags. A warm pane is ready on the first check and pays no poll.
READY_TIMEOUT=120
READY_POLL=0.5
# Note the wait every this many polls, so a slow launch leaves a trace in
# .supervisor.log instead of looking like a hang.
READY_NOTE_POLLS=10
# A readiness check can fail hard instead of being "not raw yet": tmux names
# no tty for the pane, or the stty binary is missing or cannot read that tty
# (toybox stty without -F, a pty the user cannot open). Those do not clear on
# their own, so after this many consecutive failures the wait names the fault
# instead of burning every poll in --ready-timeout. A cold start that has a
# tty but is not raw yet still gets the whole deadline.
READY_FAILS=3
# Set by wait_ready: seconds spent polling, and on a hard failure why the pane
# never became ready, the exact stty command, the tty and stty's error, for
# the log and the failure line.
READY_ELAPSED=0.0
READY_REASON=''
READY_STTY=''
READY_TTY=''
READY_ERROR=''
# The last stty -a reading, flattened to one line, and whether the resting
# prompt was already on screen while the tty stayed canonical. That pair is
# the #138 timeout: a drawn TUI whose pty never went raw is a late or stuck
# client, not a cold start, so the failure names it and records the reading
# with the last pane lines in .supervisor.log.
READY_STTY_OUT=''
READY_DRAWN=0
# A ready TUI can still swallow the Enter: the brief lands in the composer and
# is never submitted, the composer clears, and the session rests at the idle
# prompt looking healthy. So the Enter is not proof. After typing, start waits
# for the input line to clear and for a turn to begin (or the chat title to
# change) with the same poll-with-deadline shape as the readiness gate. The
# brief is never retyped automatically: a swallowed send is reported as
# sent=no with the pane, not doubled.
SUBMIT_TIMEOUT=20
# Set by await_submission: the signal that proved the send and the time it took.
SUBMIT_PROOF=''
SUBMIT_ELAPSED=0.0
# The /model picker (#125). The client has no --model flag, no environment
# override and no per-worktree setting: its model is one config key that the
# TUI's `/model` picker writes, so the picker is the only per-session switch.
# Its aid line is what says the frame is open; an entry's name line carries
# `•` and the line under it carries the only per-model price the client
# prints (`2x` for a model whose hour costs two, a phrase with no multiplier
# for one that spends none). Every step is read back from the pane.
MODEL_PICKER_AID='choose model'
MODEL_PICKER_TIMEOUT=15
MODEL_PICKER_POLL=0.5
# Up to this many arrow keys before the walk is called stuck. The real list is
# a few screens long, so this is a runaway guard, not a limit on the list.
MODEL_PICKER_STEPS=40
# Set by model_resolve: the entry --model named, its price line, and why a
# name matched nothing. Set by model_choose: the seconds the switch took.
MODEL_RESOLVED=''
MODEL_PRICE=''
MODEL_ERROR=''
# Set by model_resolve: whether the name matched several entries. Ambiguity is
# not absence, so the scroll search must not walk the list over it.
MODEL_AMBIGUOUS=0
# The last pane captured by model_frame_get, which is the frame the search and
# the walk both read.
MODEL_FRAME=''
PICKER_ELAPSED=0
# The key the switch writes (#134). The client has one settings.json and the
# model is one key in it, so two launches that switch in the same minute race
# for it and the loser runs, and bills, the other launch's model. A launch
# snapshots the key, switches under a lock in the config dir, and writes the
# snapshot back once the brief is submitted. The lock waits up to this long
# before the launch gives up: it spans one switch and one submission.
MODEL_LOCK_TIMEOUT=300
MODEL_LOCK_POLL=0.5
# Set by model_key_take/model_key_put_back: the value to put back, whether the
# file had one at all, why the guard could not be taken, and whether this
# process owns the lock right now.
MODEL_KEY_SAVED=''
MODEL_KEY_MODE=''
MODEL_KEY_ERROR=''
MODEL_LOCK_HELD=0
# Preflight: `freebuff --version` must answer inside this many seconds, or the
# start says so instead of waiting out the readiness gate. A client that exists
# but cannot execute (the glibc binary on bionic Termux, #89) is the failure
# #98 is about, so the probe runs the command rather than testing -x.
PREFLIGHT_TIMEOUT=5

usage() {
    cat <<'USAGE'
Spawn parallel Freebuff agents in isolated git worktrees.

  spawn-freebuff-agent start --issue N [options]
      Create .worktrees/<name> on a new branch, write .task.md, and launch
      Freebuff in tmux session fb-<name> at 180x55.

      --issue N          GitHub issue number (required)
      --name NAME        worktree/session name (default: issue-N)
      --branch BRANCH    new branch (default: issue/N)
      --base REF         base ref (default: main)
      --task-file FILE   use a custom brief instead of the generic one
      --title TEXT       issue title (otherwise read with gh)
      --url URL          issue URL (otherwise read with gh)
      --sdk-dir DIR      write sdk.dir into local.properties
      --auto-stop        stop fb-<name> after the agent finishes
      --idle-seconds N   idle window for --auto-stop (default: 120)
      --poll N           watcher poll interval in seconds (default: 5)
      --ready-timeout N  seconds to wait for the TUI to take raw input
                         (default: 120); a cold first launch can need more
                         than the old fixed 45s
      --ready-poll N     seconds between readiness checks (default: 0.5)
      --trust-agents     pass --trust-agents to Freebuff, which loads this
                         worktree's .agents files and mcp.json without
                         asking. It trusts repository-supplied code with
                         your permissions, so it is opt-in and never a
                         default; the vendor's own help describes it as
                         "for CI", not a general answer to every prompt.
                         Without it, a launch that stops at the trust
                         prompt fails at once and names the directory.
      --submit-timeout N seconds after the Enter to see the turn begin or the
                         chat title change (default: 20); a brief that never
                         proves submission is reported as sent=no and the
                         session is stopped, never retyped
      --max-sessions N   refuse to start while N fb-* sessions are live
      --wait-slot [N]    wait up to N seconds (default: 300) for a free slot
                         instead of failing; requires --max-sessions
                         With N > 1, each send is jittered by a random delay
                         so a burst does not reach the TUI in one second.
                         A launch that lands while another client is still
                         booting is delayed the same way before tmux starts.
      --no-start         create the worktree and brief, do not launch
      --prompt TEXT      send this message instead of the default brief
      --model NAME       choose this model in the TUI before the brief is
                         typed: an exact picker name, or a unique
                         case-insensitive substring of one (`fast` is
                         `DeepSeek V4.1 Flash Fast`). The client has no flag
                         for it, so its /model picker is driven and the
                         footer is read back before a key of the brief is
                         sent. The run prints model=<name>
                         price=<free|Nx|paid|daily>; `free` means the picker
                         printed no hour multiplier under that entry, so the
                         session spends none of the daily budget, while
                         `paid` and `daily` are a Paid plan and a per-day
                         session cap. A name the frame does not draw is
                         found by scrolling the list. An ambiguous or
                         unknown name fails before anything is sent. The
                         client keeps its model in one global key, so the
                         value found before the switch is put back once the
                         brief is submitted.
      --no-gh            do not label or comment on the issue
      --no-check         skip the preflight that names a missing tmux,
                         freebuff, stty or git before anything is created
                         (FREEBUFF_SKIP_PREFLIGHT=1 does the same)
      --wake-lock        ask Termux for a partial wake lock before tmux starts,
                         so a run can outlive the screen; optional and never
                         fatal, recorded in .supervisor.log and never released
                         (FREEBUFF_WAKE_LOCK=1 does the same)
      --dry-run          print the plan, change nothing
      --help             this text

  spawn-freebuff-agent status NAME [--lines N] [--no-gh] [--json] [--explain]
                              [--source pane|log|concord|auto] [--window N]
      Show the session, input mode, result state, pane tail, branch, last
      commit and PR. model=<name> hours=<free|Nx|paid|daily> is the model
      the run was launched with, absent when it chose none. hours=N/M is
      this run's reading of the account usage;
      when the pane carries none, the last ledger line is shown with its age
      (hours=N/M age=47m), and no history at all is hours=-.
      --lines N   pane lines to show (default: 25)
      --no-gh     do not ask gh for the PR
      --json      emit the same fields as one JSON object, plus an evidence
                  object naming the source, the rule, the matched line and
                  the window, turn_state/turn_outcome from the turn log and
                  the Concord fields when one is read
      --explain   print the classification decision line by line: every
                  marker checked, the source that won, and when two are
                  present, the losing source and its verdict
      --source S  where session_state comes from: pane (default) reads the
                  terminal. log reads the client's per-chat turn log and
                  reports turn_state=working|finished|failed with
                  turn_outcome=lastMessage|error. concord reads the
                  worktree's .concord/WORK_STATE.json and names the task an
                  agent reported. auto prefers the log, then Concord, and
                  falls back to the pane naming the reason (log=<reason>,
                  concord=<reason>) so a missing or corrupt file never
                  becomes `unknown` by accident
      --window N  pane lines the classifier reads (default: 40)

  spawn-freebuff-agent list
      List worktrees with session state, running flag and idle time.

  spawn-freebuff-agent sessions [--no-gh] [--json] [--source S]
      One table over every fb-* session and every worktree: live state, idle
      time, attached autostop watcher, whether a worktree exists, the result
      state, the branch, the open PR, the model the run was launched with
      (`Name (free)`, `Name (2x)` or -), the wake lock recorded at start and
      the last account hours reading (N/M for a live read, N/M age=47m for
      the .supervisor-hours ledger, - when there is neither).
      Sessions with no worktree are listed here instead of only being
      reapable by gc --all. --json emits the same rows as an array of
      objects, with the model as its own object ({name, hours}). --source
      selects the live STATE column the same way status does (pane, log,
      concord or auto).

  spawn-freebuff-agent hours [NAME] [--source pane|account] [--json]
      Read the remaining Freebuff hour budget. The default source is a live
      pane: the welcome panel's `N/M hours remaining` first, then the fraction
      in the footer next to the model (`DeepSeek V4.1 Flash 10/17 • high`).
      NAME defaults to any live fb-* session, and the value is an observation
      with an age (the seconds since the pane last changed), never an estimate.
      --source account
                  ask the account API instead: one GET with the client's
                  default.authToken from ~/.config/manicode/credentials.json,
                  no cookie jar. Prints hours=5/21 reset=2026-11-27T23:00:00Z
                  session=- source=account, where the figures are the daily
                  remaining and limit divided by five, the unit the TUI draws.
                  A token the server rejects is named as hours=unknown
                  source=account status=unauthorized (exit 2); a missing or
                  tokenless credentials file prints account=unconfigured and
                  falls back to the pane.
      --json      emit the same fields as one JSON object, with remaining,
                  limit and reset_at (null when the pane is the source)
      Prints hours=unknown and exits 2 when no live pane can be read.

  spawn-freebuff-agent models [NAME] [--free] [--json]
      List the models the client offers, read from a live session's /model
      picker: one `model=<name> hours=<free|2x|paid|daily>` line each, where
      `free` means the entry carries no hour multiplier, so a session on it
      spends none of the daily budget. The client has no catalog command, so
      the picker is the catalog: it is opened with /model, walked to the end
      of the list (the frame draws one page and the arrow keys scroll it) and
      closed with Escape, leaving the session as it was. Nothing is
      submitted, so listing spends no hours. NAME defaults to any live fb-*
      session. Prints model=none and exits 1 when there is no live session,
      and refuses to type into a working or refused one.
      --free      only the entries that carry no hour multiplier: the list a
                  launch should pick from when the account's hours are short
      --json      emit the same rows as one JSON object

  spawn-freebuff-agent gui --snapshot FILE [--watch N] [--no-gh] [--source S]
      Write one self-contained HTML page from `sessions --json`: one card
      per session with done-versus-working visible at a glance and the model
      it was launched with, with its cost class, beside the hours reading.
      No server, no script, no external assets, so it opens from file://
      offline.
      --watch N   rewrite the file every N seconds (adds a meta refresh)
      --no-gh     do not ask gh for the PR
      --source S  pane, concord or auto for the STATE column (see status)

  spawn-freebuff-agent gui --serve [--port N] [--host H] [--token T] [--read-only]
                              [--allow-host NAME] [--ttyd [--interactive]]
                              [--source S]
      Serve the dashboard and JSON API from python3's standard library:
      GET / is the --snapshot page, GET /api/sessions is `sessions --json`
      verbatim and GET /api/session/<name>/pane is `status --json`. POST
      /api/session/<name>/stop[?graceful=1], /api/session/<name>/send (JSON
      {"text": ...}) and /api/gc[?dry=1] run the matching CLI command and
      answer 202 with its key=value output. The served page carries Stop and
      gc forms that post to those routes; a form submission is
      cookie-authenticated, so it must carry the page nonce, passes an Origin
      check, and a successful stop answers 303 See Other to / (gc to the
      report). Binds 127.0.0.1:7788 by default;
      a non-loopback host is refused unless --token is given. Without --token
      one is generated and printed once. Every POST needs the token even on
      loopback; --read-only answers them 403. Only loopback Host names (and
      --host) are served; a foreign Host is 421, so a rebinding name gets
      nothing. --allow-host adds a name a proxy keeps, repeatable. No TLS:
      put a reverse proxy in front for LAN or Tailscale access.
      --ttyd          add a terminal link per session; GET /tty/<name> starts
                      one loopback ttyd of `tmux attach -t fb-<name>` on
                      demand and redirects to it. Read-only unless
                      --interactive, which adds ttyd's -W.
      --interactive   let the browser type into the agent; refused with
                      --read-only
      --source S      pane, concord or auto, forwarded to sessions and to
                      the pane route's status, so the page and the JSON API
                      name the same source and the same loser

  spawn-freebuff-agent attach NAME
      Attach to the tmux session (detach with Ctrl-b d).

  spawn-freebuff-agent send NAME TEXT
      Send a follow-up message to a running agent. `send NAME -- TEXT` passes
      text that starts with a dash. It refuses a pane on the
      concurrent-session, hours or released-session overlay instead of typing
      into it.

  spawn-freebuff-agent watch NAME [--idle-seconds N] [--poll N] [--timeout N]
      Report working/idle/done/blocked/failed/refused/unknown/missing
      transitions. Exits 0 when the agent is done or the pane has been idle
      past the window, 1 on timeout, 2 when the session is gone, 3 when the
      agent reported blocked and 4 when it reported failed. Never stops
      anything.

  spawn-freebuff-agent autostop NAME [--idle-seconds N] [--poll N] [--timeout N]
      Watch, then stop fb-<name> and record the run evidence. This is what
      start --auto-stop runs detached. A done, blocked or failed result stops
      the session; the exit status is watch's (0, 3 or 4).

  spawn-freebuff-agent notify NAME
      Report the next turn end from the client's per-chat log.jsonl: a
      turn end is an earlier signal than .agent-result, not a replacement for
      it. Each call reads from a cursor in the worktree and advances it, so a
      turn fires once; the first call arms the cursor at the end of the log
      and reports nothing, so history is not replayed. A complete start/end
      pair prints event=turn-end with turn_state=finished|failed and
      turn_outcome=lastMessage|error; otherwise event=none with a reason.
      Missing chat directory or log.jsonl prints reason=no-turn-log and
      exits 2. It never sends, stops or waits.

  spawn-freebuff-agent monitor [--interval N] [--once] [--stuck-after N]
                               [--json] [--ledger PATH] [--ledger-max-bytes N]
                               [--fail-on unknown]
      Follow every live fb-* session and record what changes, not what is
      steady. Each session is classified once per scan with the same state
      function status uses, and every transition appends one line to
      .state-monitor.jsonl in the repository root:
      {ts,name,state,prev,rule,fingerprint,stuck_seconds}, mode 0600. A
      fingerprint is the window hash behind the verdict, or the state and
      rule when a file gave it, so two scans can say whether the same pane
      produced the same state. Prints one line per transition
      (`ts=… name=… state=… prev=… rule=…`) and nothing while a session holds
      its state; a read-only monitor, it never sends, stops or waits.
      --interval N        seconds between scans (default: 10)
      --once              one scan and exit, for cron or a test; never sleeps
      --stuck-after N     flag a non-terminal state held longer than N
                          seconds (default: 1800). The flag is recorded in
                          the ledger and reported once per run of that state
      --json              one JSON object per reported line, with the ledger
                          fields and `flag` when it reports stuck or flapping
      --ledger PATH       ledger file (default: .state-monitor.jsonl in the
                          repository root)
      --ledger-max-bytes N
                          rotate the ledger to PATH.1 at N bytes (default:
                          1048576)
      --fail-on unknown   exit 3 when any live session is unclassified, for
                          CI; without it the exit status is 0
      Flapping is more than three transitions within ten minutes, reported
      once when the fourth arrives: a bound, not a count of polls.

  spawn-freebuff-agent stop NAME [--graceful [--wait N]]
      Kill the tmux session; the worktree and branch are left in place.
      --graceful sends Escape, waits up to N seconds (default: 20) for the turn
      to end, then stops, recording the pane state. It refuses to kill a
      session that is still working when the wait expires.

  spawn-freebuff-agent gc [--idle-hours N] [--prune-worktrees] [--dry-run]
      Stop finished sessions, sessions idle past N hours (default: 12),
      sessions stuck on the concurrent-session overlay, and fb-* sessions
      whose worktree no longer exists. Busy and approval panes are skipped.
      --prune-worktrees also prints the git worktree remove / git branch -d
      command for each stopped session except a refused one; it never runs
      the command. Worktrees and branches are never removed. --all is still
      accepted, but a worktree-less session is stopped by plain gc now.

Environment:
  FREEBUFF_BIN        freebuff executable (default: freebuff on PATH)
  FREEBUFF_TMUX       tmux executable (default: tmux on PATH, then nix-shell)
  FREEBUFF_STTY       stty executable for the raw-mode check (default: stty on
                      PATH); point it at GNU stty if the PATH one has no -F
  FREEBUFF_START_JITTER  upper bound in seconds for the random delay before a
                         send when --max-sessions allows several, and before
                         a launch that races another client's boot (default:
                         2N; 0 disables both waits)
  FREEBUFF_TTYD       ttyd executable for gui --ttyd (default: ttyd on PATH)
  FREEBUFF_WAKE_LOCK  1 acquires the Termux wake lock for every start, like
                      --wake-lock
  FREEBUFF_SUPERVISOR_ROOT  repository root override (tests)
  GH_BIN              gh executable (default: gh on PATH)

Notes:
  - The TUI needs a 180x55 pane. Smaller panes stay in canonical mode and
    silently ignore the prompt; this tool waits for -icanon before sending,
    re-checking every --ready-poll seconds for up to --ready-timeout.
  - A worktree that carries .agents/ (or an mcp.json) makes Freebuff print
    `Load and run these? [y/N]` before the TUI mounts. start stops at once,
    types nothing and names the directory: answer `y` once in an interactive
    launch there to record the trust, or rerun start with --trust-agents.
  - A wait that gives up names the timeout it used, prints the last pane
    lines and records the elapsed seconds, those pane lines and the last
    stty -a reading in .supervisor.log, so a slow cold launch is
    distinguishable from a hung TUI. A resting prompt on a tty that stayed
    canonical is ready=timeout reason=canonical-drawn, printed with
    retry=safe: the pane is drawn, so a larger --ready-timeout cannot help.
  - --model drives the client's own /model picker. There is no client flag,
    environment override or per-worktree setting for the model, so start
    types /model, moves the `›` marker with the arrow keys the frame prints,
    and presses Enter only once that marker sits on the chosen name. The
    footer must then name the model, or the launch fails with no brief sent
    and the session stopped. The switch writes freebuffModelKey in the one
    settings.json every launch shares, so start snapshots the key it found,
    switches under a lock in that config dir, and writes the snapshot back
    once the brief is submitted — and on every later failure, so a launch
    that never sent leaves the key as it found it. A config whose key cannot
    be read is not switched at all, and a restore that fails is recorded as
    model_key=restore-failed in .supervisor.log instead of passing silently.
    The choice and its cost class are recorded in .supervisor.log, and status,
    sessions and the GUI card report them.
  - A ready pane can still swallow the Enter. After typing, start waits for
    the input line to clear and for the turn to begin (or the chat title to
    change) and prints sent=yes with the signal that proved it. A send that
    never proves submission prints sent=no with the pane, stops the session
    and exits non-zero; the brief is not retyped.
  - A running agent runs shell commands with its normal approvals. Do not
    attach and type while it is working.
  - Every hours=N/M observation is appended to .supervisor-hours, one line
    per read, so status and sessions can still show the last account usage
    after the session that showed it is gone. A ledger reading is always
    labelled with its age; a number without an age came from this run.
  - A brief is hashed into .supervisor-briefs.jsonl (last 20 kept) before it
    is typed; a repeat inside that window is a hard error and sends nothing,
    because Freebuff treats a repeated message as scripted use and counts a
    strike against the account. A brief the vendor refused is marked in the
    same ledger, kept past the window and never sent again.
  - Before a launch creates anything, start asks the account API for the
    remaining hours (the reader behind hours --source account) and refuses an
    empty budget as refused=hours with the reset time, without spending a
    worktree or a session slot. Only a definitive zero refuses, --model skips
    the check because a free model spends no hours, and an absent token, an
    absent curl or a server that does not answer never blocks a launch.
  - A refusal (the concurrent-session or hours overlay, or the vendor's
    anti-automation answer in the turn text) is recorded in
    .worktrees/<name>/.refusal and .supervisor.log. start prints refused=yes,
    or refused=hours with hours=N/M when the panel shows the account's usage,
    plus a hint naming the next step, and exits non-zero; an overlay gets no
    keys at all, and status keeps refused until stop clears it.
  - --wake-lock runs termux-wake-lock once, after the preflight and before
    tmux new-session, and records wake_lock=acquired|unavailable|failed in
    .supervisor.log. It is never fatal: without the binary the run starts
    unprotected and says so. The tool never releases the lock, because it is
    service-scoped: stop on one session would unlock every session and the
    GUI. It dies with the Termux app, keeps the CPU awake while held and costs
    battery; release it yourself with termux-wake-unlock. status and sessions
    report the value recorded at start, not a claim that it is still held.
  - Completion is either the agent's .agent-result file (stock brief) or an
    idle pane after the window; the pane heuristic is tied to the TUI.
  - The tool never deletes a worktree or branch. Use git worktree remove and
    git branch -D explicitly when the PR is done.
USAGE
}

die() {
    printf 'spawn-freebuff-agent: %s\n' "$*" >&2
    exit 1
}

note() {
    printf '%s\n' "$*"
}

is_num() {
    case "${1:-}" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

is_duration() {
    # is_duration VALUE -> 0 for a positive number of seconds. Decimals are
    # allowed because --ready-poll defaults to 0.5 and sleep accepts fractions
    # on every target; zero is refused so a poll cannot busy-loop.
    case "${1:-}" in
        ''|*[!0-9.]*|*.*.*) return 1 ;;
        *[1-9]*) return 0 ;;
        *) return 1 ;;
    esac
}

valid_name() {
    case "${1:-}" in
        ''|*[!A-Za-z0-9_-]*) return 1 ;;
        *) return 0 ;;
    esac
}

