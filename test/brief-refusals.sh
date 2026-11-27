#!/usr/bin/env bash
# Area: the brief ledger (#48) and the refusal vocabulary and state (#47).

# shellcheck shell=bash
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

# ---- brief ledger: never the same text twice (#48) ----

# Reach the real send path: the lib's stub freebuff and fake stty report raw
# mode, and this area only needs a clean ledger and a ready pane.
PATH="$TMP/bin:$PATH"
export PATH
export FREEBUFF_BIN="$TMP/bin/freebuff"
rm -f "$REPO/.supervisor-briefs.jsonl"
rm -f "$FAKE_DIR/ready_after" "$FAKE_DIR/pane_after_send"
: >"$FAKE_DIR/ready"
printf '%s\n' "$IDLE_PANE" >"$FAKE_DIR/pane"
fake_clear
: >"$FAKE_DIR/sent"

sent_text() {
    # sent_text NAME -> the literal text argument of the last send
    grep -F -- '-l' "$FAKE_DIR/sent" | grep -F -- "fb-$1" | tail -n 1
}

if launch_brief test-brief-a 1002 >"$TMP/start.out" 2>&1; then rc=0; else rc=$?; fi
check test "$rc" -eq 0
check contains "$(cat "$TMP/start.out")" 'started=yes'
sent_a=$(sent_text test-brief-a)
check contains "$sent_a" 'Session test-brief-a'
check contains "$sent_a" "worktree $REPO/.worktrees/test-brief-a"
check contains "$sent_a" 'Issue #1002'
check contains "$(cat "$REPO/.supervisor-briefs.jsonl")" '"name": "test-brief-a"'
check grep -qxF '.supervisor-briefs.jsonl' "$REPO/.git/info/exclude"

if launch_brief test-brief-b 1003 >"$TMP/start.out" 2>&1; then rc=0; else rc=$?; fi
check test "$rc" -eq 0
sent_b=$(sent_text test-brief-b)
check contains "$sent_b" 'Issue #1003'
check test "$sent_a" != "$sent_b"
check test "$(grep -c . "$REPO/.supervisor-briefs.jsonl" || true)" = 2

# start --auto-stop persists the watcher pid in the log watcher_state reads,
# so sessions shows pid:N while it lives and dead once it is killed.
if launch_brief test-auto-pid 1009 --auto-stop --idle-seconds 3600 --poll 60 \
    >"$TMP/start.out" 2>&1; then rc=0; else rc=$?; fi
check test "$rc" -eq 0
AUTO_WT="$REPO/.worktrees/test-auto-pid"
check grep -qE '^autostop=pid:[0-9]+$' "$AUTO_WT/.supervisor.log"
auto_pid=$(sed -n 's/^autostop=pid:\([0-9]*\)$/\1/p' \
    "$AUTO_WT/.supervisor.log" | tail -n 1)
check test -n "$auto_pid"
check kill -0 "$auto_pid"
out=$(bash "$TOOL" --root "$REPO" sessions --no-gh)
check test "$(printf '%s\n' "$out" | awk '$1 == "test-auto-pid" { print $4 }')" = "pid:$auto_pid"
kill "$auto_pid" 2>/dev/null || true
i=0
while [ "$i" -lt 100 ] && kill -0 "$auto_pid" 2>/dev/null; do
    sleep 0.05
    i=$((i + 1))
done
out=$(bash "$TOOL" --root "$REPO" sessions --no-gh)
check test "$(printf '%s\n' "$out" | awk '$1 == "test-auto-pid" { print $4 }')" = dead

# A watcher survives the process group that launched it when setsid is
# available: start in a new session, tear that group down, and the recorded
# watcher must still answer kill -0.
if command -v setsid >/dev/null 2>&1 && setsid -w true 2>/dev/null; then
    SURVIVE_WT="$REPO/.worktrees/test-auto-survive"
    # The previous launch left its turn in the pane; readiness needs the
    # resting prompt, and a leftover busy pane would spend the whole
    # --ready-timeout before failing for the wrong reason. Reset it, keep the
    # gate short, and report the start's own output when it does fail.
    printf '%s\n' "$IDLE_PANE" >"$FAKE_DIR/pane"
    if setsid -w bash -c 'echo $$ >"$1"; shift; exec "$@"' _ \
        "$TMP/survive.pgid" bash "$TOOL" --root "$REPO" start --issue 1016 \
        --name test-auto-survive --branch test/auto-survive --title T --url U \
        --auto-stop --idle-seconds 3600 --poll 60 --ready-timeout 10 \
        >"$TMP/start.out" 2>&1; then rc=0; else rc=$?; fi
    check test "$rc" -eq 0
    [ "$rc" -eq 0 ] || printf 'start out:\n%s\n' "$(cat "$TMP/start.out")" >&2
    survive_pgid=$(cat "$TMP/survive.pgid")
    survive_pid=$(sed -n 's/^autostop=pid:\([0-9]*\)$/\1/p' \
        "$SURVIVE_WT/.supervisor.log" | tail -n 1)
    check test -n "$survive_pid"
    kill -TERM -- "-$survive_pgid" 2>/dev/null || true
    sleep 0.2
    check kill -0 "$survive_pid"
    kill "$survive_pid" 2>/dev/null || true
fi

# Seed older entries so the next success also proves the window is trimmed
# to the last 20 rather than growing without bound.
for i in $(seq 1 25); do
    printf '{"at": "seed", "name": "seed", "branch": "seed", "hash": "seed%s"}\n' \
        "$i" >>"$REPO/.supervisor-briefs.jsonl"
done

# A reused --prompt is the case the ledger exists for: send it once, then the
# same literal text from another session must fail before any keystroke.
if launch_brief test-brief-c 1004 --prompt 'one identical brief' \
    >"$TMP/start.out" 2>&1; then rc=0; else rc=$?; fi
check test "$rc" -eq 0
check contains "$(sent_text test-brief-c)" 'one identical brief'
check test "$(grep -c . "$REPO/.supervisor-briefs.jsonl" || true)" = 20

: >"$FAKE_DIR/sent"
if launch_brief test-brief-d 1005 --prompt 'one identical brief' \
    >"$TMP/start.out" 2>&1; then rc=0; else rc=$?; fi
check test "$rc" -eq 1
check contains "$(cat "$TMP/start.out")" 'refusing a duplicate brief'
check contains "$(cat "$TMP/start.out")" 'test-brief-c'
check contains "$(cat "$TMP/start.out")" 'scripted or automated use'
check test ! -s "$FAKE_DIR/sent"
check test ! -e "$REPO/.worktrees/test-brief-d"
check test "$(grep -c 'fb-test-brief-d' "$FAKE_DIR/session" || true)" = 0

# Several allowed slots jitter the send; the dry run names the bound only.
out=$(bash "$TOOL" --root "$REPO" start --issue 1006 --name test-brief-j \
    --branch test/brief-j --title T --url U --max-sessions 2 --dry-run)
check contains "$out" 'jitter_max=4s'
check contains "$out" 'brief_hash='
check test ! -e "$REPO/.worktrees/test-brief-j"

# ---- refusal vocabulary and refusal state (#47) ----

# The overlay refuses before the brief: no keys at all, refused=yes, a
# non-zero exit, and the sentence recorded instead of the pane.
printf '%s\n' "$REFUSED_PANE" >"$FAKE_DIR/pane"
: >"$FAKE_DIR/sent"
: >"$FAKE_DIR/killed"
if launch_brief test-refuse-overlay 1007 >"$TMP/start.out" 2>&1; then rc=0; else rc=$?; fi
check test "$rc" -ne 0
check contains "$(cat "$TMP/start.out")" 'refused=yes'
check contains "$(cat "$TMP/start.out")" 'concurrent-session limit'
check test ! -s "$FAKE_DIR/sent"
check grep -qxF 'fb-test-refuse-overlay' "$FAKE_DIR/killed"
REFUSE_WT="$REPO/.worktrees/test-refuse-overlay"
check test -f "$REFUSE_WT/.refusal"
check contains "$(cat "$REFUSE_WT/.refusal")" 'concurrent-session limit'
check contains "$(cat "$REFUSE_WT/.supervisor.log")" 'refused at='
check contains "$(cat "$REFUSE_WT/.supervisor.log")" 'concurrent-session limit'
check test -z "$(grep -F 'pane:' "$REFUSE_WT/.supervisor.log" || true)"

# the session is gone, but status keeps the refusal until stop clears it
printf '%s\n' "$IDLE_PANE" >"$FAKE_DIR/pane"
out=$(bash "$TOOL" --root "$REPO" status --no-gh test-refuse-overlay)
check contains "$out" 'session_state=refused'
out=$(bash "$TOOL" --root "$REPO" stop test-refuse-overlay)
check contains "$out" 'stopped=no'
check test ! -f "$REFUSE_WT/.refusal"
out=$(bash "$TOOL" --root "$REPO" status --no-gh test-refuse-overlay)
check test -z "$(printf '%s\n' "$out" | grep 'session_state=refused' || true)"

# The anti-automation refusal arrives as a finished turn after the send. The
# fake pane flips only on Enter, so readiness sees a healthy prompt and start
# must notice the refusal afterwards instead of printing started=yes.
printf '%s\n' "$IDLE_PANE" >"$FAKE_DIR/pane"
printf '%s\n' "$STRIKE_PANE" >"$FAKE_DIR/pane_after_send"
: >"$FAKE_DIR/sent"
if launch_brief test-refuse-turn 1008 --prompt 'strike me once' \
    >"$TMP/start.out" 2>&1; then rc=0; else rc=$?; fi
check test "$rc" -ne 0
check contains "$(cat "$TMP/start.out")" 'refused=yes'
check contains "$(cat "$TMP/start.out")" 'sent over and over'
check test -s "$FAKE_DIR/sent"
TURN_WT="$REPO/.worktrees/test-refuse-turn"
check test -f "$TURN_WT/.refusal"
check contains "$(cat "$TURN_WT/.supervisor.log")" 'sent over and over'
check contains "$(cat "$REPO/.supervisor-briefs.jsonl")" '"refused": true'
check test -z "$(grep -F 'pane:' "$TURN_WT/.supervisor.log" || true)"

# the pane is back at the resting prompt, but the refusal survives it
printf '%s\n' "$IDLE_PANE" >"$FAKE_DIR/pane"
out=$(bash "$TOOL" --root "$REPO" status --no-gh test-refuse-turn)
check contains "$out" 'session_state=refused'

# A refused brief is kept in the #48 ledger past the 20-entry window, so a
# later retry with the same text is refused locally with nothing sent.
for i in $(seq 1 25); do
    printf '{"at": "seed2", "name": "seed2", "branch": "seed2", "hash": "seed2%s"}\n' \
        "$i" >>"$REPO/.supervisor-briefs.jsonl"
done
if launch_brief test-refuse-next 1010 >"$TMP/start.out" 2>&1; then rc=0; else rc=$?; fi
check test "$rc" -eq 0
check test "$(grep -c . "$REPO/.supervisor-briefs.jsonl" || true)" = 21
: >"$FAKE_DIR/sent"
if launch_brief test-refuse-retry 1011 --prompt 'strike me once' \
    >"$TMP/start.out" 2>&1; then rc=0; else rc=$?; fi
check test "$rc" -eq 1
check contains "$(cat "$TMP/start.out")" 'already refused'
check contains "$(cat "$TMP/start.out")" 'never resent'
check test ! -s "$FAKE_DIR/sent"
check test ! -e "$REPO/.worktrees/test-refuse-retry"

# send never types into the overlay either
fake_session test-refuse-send "$REFUSED_PANE"
: >"$FAKE_DIR/sent"
if bash "$TOOL" --root "$REPO" send test-refuse-send 'hello' \
    >"$TMP/start.out" 2>&1; then rc=0; else rc=$?; fi
check test "$rc" -ne 0
check contains "$(cat "$TMP/start.out")" 'concurrent-session overlay'
check test ! -s "$FAKE_DIR/sent"
fake_clear

# ---- the hours overlay (#107) ----

# The hours overlay is a refusal, not a slow start: it is already on screen
# before the brief, so no keys are typed, the submit window is never entered,
# and the output names the refusal and both ways out instead of a timeout.
printf '%s\n' "$HOURS_PANE" >"$FAKE_DIR/pane"
: >"$FAKE_DIR/sent"
: >"$FAKE_DIR/killed"
if launch_brief test-refuse-hours 1017 --submit-timeout 20 \
    >"$TMP/start.out" 2>&1; then rc=0; else rc=$?; fi
check test "$rc" -ne 0
HOURS_OUT=$(cat "$TMP/start.out")
check contains "$HOURS_OUT" 'refused=hours'
check contains "$HOURS_OUT" 'Not enough hours'
check contains "$HOURS_OUT" 'hint=stop finished sessions with:'
check contains "$HOURS_OUT" 'wait for the daily hours to refill'
# The captured panel carries no usage figure, so no hours= line is invented.
check test -z "$(printf '%s\n' "$HOURS_OUT" | grep '^hours=' || true)"
check test ! -s "$FAKE_DIR/sent"
check grep -qxF 'fb-test-refuse-hours' "$FAKE_DIR/killed"
HOURS_WT="$REPO/.worktrees/test-refuse-hours"
check test -f "$HOURS_WT/.refusal"
check contains "$(cat "$HOURS_WT/.refusal")" 'Not enough hours'
check contains "$(cat "$HOURS_WT/.supervisor.log")" 'refused at='
check test -z "$(grep -F 'pane:' "$HOURS_WT/.supervisor.log" || true)"
# No fraction was on the panel, so no ledger line is invented for this session.
check test -z "$(grep 'session=fb-test-refuse-hours$' "$REPO/.supervisor-hours" 2>/dev/null || true)"

# A panel that also draws the account's usage reports it as hours=N/M; the
# sentence alone does not carry a fraction, so nothing is guessed there.
printf '%s\n%s\n' "$HOURS_PANE" 'Hours today: 1/2' >"$FAKE_DIR/pane"
: >"$FAKE_DIR/sent"
if launch_brief test-refuse-hours-quota 1018 >"$TMP/start.out" 2>&1; then rc=0; else rc=$?; fi
check test "$rc" -ne 0
check contains "$(cat "$TMP/start.out")" 'refused=hours'
check contains "$(cat "$TMP/start.out")" 'hours=1/2'
check test ! -s "$FAKE_DIR/sent"
# The observation is appended to the repository ledger with its source (#108).
check contains "$(cat "$REPO/.supervisor-hours")" \
    'hours=1/2 source=panel session=fb-test-refuse-hours-quota'

# The observed case: the pane was ready and the Enter was taken, then the
# overlay appeared in place of the turn. That is the same refusal, so the
# first submission poll reports it instead of spending --submit-timeout.
printf '%s\n' "$IDLE_PANE" >"$FAKE_DIR/pane"
printf '%s\n' "$HOURS_PANE" >"$FAKE_DIR/pane_after_send"
: >"$FAKE_DIR/sent"
if launch_brief test-refuse-hours-turn 1019 --prompt 'hours after the send' \
    --submit-timeout 20 >"$TMP/start.out" 2>&1; then rc=0; else rc=$?; fi
check test "$rc" -ne 0
HOURS_TURN_OUT=$(cat "$TMP/start.out")
check contains "$HOURS_TURN_OUT" 'refused=hours'
check contains "$HOURS_TURN_OUT" 'submit_elapsed=0.0s'
check contains "$HOURS_TURN_OUT" 'resent=no'
check test -s "$FAKE_DIR/sent"
HOURS_TURN_WT="$REPO/.worktrees/test-refuse-hours-turn"
check contains "$(cat "$HOURS_TURN_WT/.refusal")" 'Not enough hours'
check contains "$(cat "$REPO/.supervisor-briefs.jsonl")" '"refused": true'
check test -z "$(grep -F 'pane:' "$HOURS_TURN_WT/.supervisor.log" || true)"

# The refused text is kept past the ledger window, so a retry after the hours
# are back is refused locally with nothing typed.
rm -f "$FAKE_DIR/pane_after_send"
printf '%s\n' "$IDLE_PANE" >"$FAKE_DIR/pane"
: >"$FAKE_DIR/sent"
if launch_brief test-refuse-hours-retry 1020 --prompt 'hours after the send' \
    >"$TMP/start.out" 2>&1; then rc=0; else rc=$?; fi
check test "$rc" -eq 1
check contains "$(cat "$TMP/start.out")" 'already refused'
check test ! -s "$FAKE_DIR/sent"
check test ! -e "$REPO/.worktrees/test-refuse-hours-retry"

# send never types into the hours overlay either
fake_session test-refuse-hours-send "$HOURS_PANE"
: >"$FAKE_DIR/sent"
if bash "$TOOL" --root "$REPO" send test-refuse-hours-send 'hello' \
    >"$TMP/start.out" 2>&1; then rc=0; else rc=$?; fi
check test "$rc" -ne 0
check contains "$(cat "$TMP/start.out")" 'hours overlay'
check test ! -s "$FAKE_DIR/sent"
fake_clear
