#!/usr/bin/env bash
# Area: the state monitor — one ledger line per transition, stuck and flapping (#43).

# shellcheck shell=bash
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

# A clean inventory and a ledger of its own: the monitor follows every live
# fb-* session, so a leftover one from another area would be recorded too.
fake_clear
LEDGER="$TMP/monitor.jsonl"
ERR="$TMP/monitor-err"
rm -f "$LEDGER" "$LEDGER.1" "$ERR"
MONWT="$REPO/.worktrees/test-mon"
mkdir -p "$MONWT"

mon_once() {
    # mon_once ARGS... -> one `--once` scan on $LEDGER, status in $rc, report
    # in $out and stderr in $ERR.
    if out=$(bash "$TOOL" --root "$REPO" monitor --once --ledger "$LEDGER" \
        "$@" 2>"$ERR"); then
        rc=0
    else
        rc=$?
    fi
}

# ---- a transition is recorded, a steady poll is not ----

fake_session test-mon "$IDLE_PANE"
mon_once
check test "$rc" -eq 0
check grep -qE '^ts=[0-9]+ name=test-mon state=idle prev= rule=resting-prompt$' <<<"$out"
check test "$(wc -l <"$LEDGER")" -eq 1

# Same pane again: the monitor says nothing and appends nothing.
mon_once
check test "$rc" -eq 0
check test -z "$out"
check test "$(wc -l <"$LEDGER")" -eq 1

fake_session test-mon "$BUSY_PANE"
mon_once
check contains "$out" 'state=working prev=idle rule=busy-marker'
check test "$(wc -l <"$LEDGER")" -eq 2

# done is the result file's word, and it is a transition like any other.
printf 'state=done\ncommit=abc1234\ntests=all\n' >"$MONWT/.agent-result"
mon_once
check contains "$out" 'state=done prev=working rule=result-file'
check test "$(wc -l <"$LEDGER")" -eq 3

# A poll after the transition changes nothing, even though it still runs.
mon_once
check test -z "$out"
check test "$(wc -l <"$LEDGER")" -eq 3
rm -f "$MONWT/.agent-result"

# ---- the ledger is the object #43 names, mode 0600 ----

check json_ok "$(sed -n '1p' "$LEDGER")"
check grep -qE '^\{"ts":[0-9]+,"name":"test-mon","state":"idle","prev":"","rule":"resting-prompt","fingerprint":"[^"]+","stuck_seconds":[0-9]+\}$' "$LEDGER"
check test "$(ls -ld "$LEDGER" | cut -c1-10)" = '-rw-------'

# ---- a stuck state is flagged once, not on every poll ----

# The ledger is the monitor's only memory, so seeding it is exactly what a
# monitor that has been watching for half an hour would have written.
: >"$LEDGER"
now=$(date +%s)
printf '{"ts":%s,"name":"test-mon","state":"working","prev":"idle","rule":"busy-marker","fingerprint":"seeded","stuck_seconds":0}\n' \
    "$((now - 2000))" >"$LEDGER"
fake_session test-mon "$BUSY_PANE"
mon_once --stuck-after 60
check test "$rc" -eq 0
check grep -qE 'state=working prev=working .*flag=stuck stuck_seconds=[0-9]+' <<<"$out"
check test "$(wc -l <"$LEDGER")" -eq 2

# The flag is in the ledger now, so the next poll stays quiet.
mon_once --stuck-after 60
check test -z "$out"
check test "$(wc -l <"$LEDGER")" -eq 2

# The flag does not restart the run clock: the transition out of the state
# still reports the whole time spent in it.
fake_session test-mon "$IDLE_PANE"
mon_once --stuck-after 60
check contains "$out" 'state=idle prev=working'
stuck_secs=$(sed -n 's/.*"stuck_seconds":\([0-9]*\)}$/\1/p' <<<"$(tail -n 1 "$LEDGER")")
check test "$stuck_secs" -ge 2000

# ---- four transitions in a burst produce one flapping report ----

: >"$LEDGER"
fake_session test-mon "$IDLE_PANE"
mon_once                        # 1: idle, the baseline
fake_session test-mon "$BUSY_PANE"
mon_once                        # 2: working
fake_session test-mon "$IDLE_PANE"
mon_once                        # 3: idle
fake_session test-mon "$BUSY_PANE"
mon_once --json                 # 4: working, over the threshold
check test "$rc" -eq 0
check contains "$out" '"flag":"flapping"'
check test "$(printf '%s\n' "$out" | grep -c '"flag":"flapping"')" -eq 1
flap=$(printf '%s\n' "$out" | grep '"flag":"flapping"')
check json_ok "$flap"

# A fifth transition is the same burst: it is recorded, not re-reported.
fake_session test-mon "$IDLE_PANE"
mon_once
check contains "$out" 'state=idle prev=working'
case "$out" in
    *flag=flapping*) check false ;;
    *) check true ;;
esac

# ---- --once never sleeps; one scan is one entry per changed session ----

: >"$LEDGER"
started=$(date +%s)
mon_once --interval 120
# Well under the interval, so an `--once` that fell through to the loop would
# show: a single scan is a few classifications, not a 120-second sleep.
check test "$(( $(date +%s) - started ))" -lt 60
check test "$(wc -l <"$LEDGER")" -eq 1

# ---- two monitors on one ledger: whole lines, never truncation ----

: >"$LEDGER"
fake_session test-conc0 "$BUSY_PANE"
for i in 1 2 3 4 5 6 7 8; do
    fake_add_session "test-conc$i"
done
bash "$TOOL" --root "$REPO" monitor --once --ledger "$LEDGER" \
    >/dev/null 2>&1 &
mon_a=$!
bash "$TOOL" --root "$REPO" monitor --once --ledger "$LEDGER" \
    >/dev/null 2>&1 &
mon_b=$!
if wait "$mon_a" "$mon_b"; then rc=0; else rc=$?; fi
check test "$rc" -eq 0
bad=0
while IFS= read -r line; do
    [ -n "$line" ] || continue
    json_ok "$line" || bad=$((bad + 1))
    case "$line" in
        *'"name":"test-conc'*'"fingerprint":"'*'","stuck_seconds":'*'}') ;;
        *) bad=$((bad + 1)) ;;
    esac
done <"$LEDGER"
check test "$bad" -eq 0
check test -z "$(grep -v '}$' "$LEDGER" || true)"
check test "$(wc -l <"$LEDGER")" -ge 9

# ---- the ledger rotates at --ledger-max-bytes ----

: >"$LEDGER"
rm -f "$LEDGER.1"
fake_session test-mon "$IDLE_PANE"
mon_once --ledger-max-bytes 1
check test "$(wc -l <"$LEDGER")" -eq 1
fake_session test-mon "$BUSY_PANE"
mon_once --ledger-max-bytes 1
check test -f "$LEDGER.1"
check test "$(wc -l <"$LEDGER")" -eq 1
check test "$(wc -l <"$LEDGER.1")" -eq 1

# ---- a session name from tmux is checked before use ----

printf 'fb-bad name\n' >"$FAKE_DIR/session"
: >"$LEDGER"
mon_once
check test "$rc" -eq 0
check test -z "$out"
check test "$(wc -l <"$LEDGER")" -eq 0
check contains "$(cat "$ERR")" 'invalid session name: fb-bad name'

# ---- --json is the ledger object itself ----

: >"$LEDGER"
fake_session test-mon "$BUSY_PANE"
mon_once --json
check test "$rc" -eq 0
check json_ok "$out"
check contains "$out" '"name":"test-mon"'
check contains "$out" '"state":"working"'
check contains "$out" '"stuck_seconds":0'
check test "$out" = "$(cat "$LEDGER")"

# ---- --fail-on unknown is the CI exit, not the default ----

fake_session test-mon "$NOMARKER_PANE"
: >"$LEDGER"
mon_once --fail-on unknown
check test "$rc" -eq 3
check contains "$out" 'state=unknown'
mon_once
check test "$rc" -eq 0

# ---- the default ledger lives beside the other ledgers and is excluded ----

rm -f "$REPO/.state-monitor.jsonl"
fake_session test-mon "$IDLE_PANE"
if out=$(bash "$TOOL" --root "$REPO" monitor --once 2>"$ERR"); then rc=0; else rc=$?; fi
check test "$rc" -eq 0
check test -f "$REPO/.state-monitor.jsonl"
check contains "$(cat "$REPO/.state-monitor.jsonl")" '"state":"idle"'
check grep -qxF '.state-monitor.jsonl' "$REPO/.git/info/exclude"
rm -f "$REPO/.state-monitor.jsonl"

# ---- the flags are rejected before anything is written ----

if out=$(bash "$TOOL" --root "$REPO" monitor --fail-on nope 2>&1); then rc=0; else rc=$?; fi
check test "$rc" -eq 1
check contains "$out" '--fail-on must be unknown'
if out=$(bash "$TOOL" --root "$REPO" monitor --ledger-max-bytes 0 2>&1); then rc=0; else rc=$?; fi
check test "$rc" -eq 1
check contains "$out" '--ledger-max-bytes must be greater than zero'
if out=$(bash "$TOOL" --root "$REPO" monitor --interval 0 2>&1); then rc=0; else rc=$?; fi
check test "$rc" -eq 1
check contains "$out" '--interval must be a number greater than zero'
if out=$(bash "$TOOL" --root "$REPO" monitor --ledger "$TMP/no-dir/l.jsonl" \
    --once 2>&1); then rc=0; else rc=$?; fi
check test "$rc" -eq 1
check contains "$out" 'ledger directory does not exist'
check contains "$(bash "$TOOL" --help 2>&1)" 'monitor [--interval N]'

fake_clear
rm -f "$LEDGER" "$LEDGER.1"
