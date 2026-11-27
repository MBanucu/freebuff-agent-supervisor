#!/usr/bin/env bash
# Area: autostop, gc, the session inventory, graceful stop and capacity.

# shellcheck shell=bash
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

# No session, no result and no readiness opt-in: a launch that cannot take
# input fails fast instead of polling the whole readiness window.
[ -d "$WT" ] || bash "$TOOL" --root "$REPO" start --issue 999 --name test-999 \
    --branch test/999 --title 'Test issue' \
    --url 'https://example.test/issues/999' --no-start >/dev/null
rm -f "$WT/.agent-result" "$WT/.supervisor.log" "$WT/.refusal"
rm -f "$FAKE_DIR/ready" "$FAKE_DIR/ready_after" "$FAKE_DIR/pane_after_send"
fake_clear

# autostop: idle agent is stopped exactly once and evidence is kept
fake_session test-999 "$IDLE_PANE"
if bash "$TOOL" --root "$REPO" autostop test-999 --idle-seconds 0 --poll 0 \
    --timeout 10 >"$TMP/watch.out" 2>&1; then rc=0; else rc=$?; fi
check test "$rc" -eq 0
check grep -qxF 'fb-test-999' "$FAKE_DIR/killed"
check test "$(grep -c . "$FAKE_DIR/killed")" = 1
check test -f "$WT/.supervisor.log"
check contains "$(cat "$WT/.supervisor.log")" 'reason=idle'
check contains "$(cat "$WT/.supervisor.log")" 'pane:'
check test -d "$WT"
check test "$(git -C "$WT" branch --show-current)" = test/999
check test -z "$(git -C "$WT" status --short)"

# gc: a busy session is skipped and dry-run changes nothing
fake_session test-999 "$BUSY_PANE"
out=$(bash "$TOOL" --root "$REPO" gc --idle-hours 1 --dry-run)
check contains "$out" 'skip name=test-999 reason=busy'
check test ! -s "$FAKE_DIR/killed"

# gc: an idle past the threshold is reported, not stopped, in dry-run
fake_session test-999 "$IDLE_PANE" "$(($(date +%s) - 7200))"
out=$(bash "$TOOL" --root "$REPO" gc --idle-hours 1 --dry-run)
check contains "$out" 'would-stop name=test-999 reason=idle'
check test ! -s "$FAKE_DIR/killed"

# gc: a done session is stopped and evidence appended, but the cleanup
# command is opt-in: the default run offers no way to lose the worktree
printf 'state=done\npr=none\n' >"$WT/.agent-result"
out=$(bash "$TOOL" --root "$REPO" gc --idle-hours 1)
check contains "$out" 'stop name=test-999 reason=done'
check test -z "$(printf '%s\n' "$out" | grep 'cleanup=' || true)"
check grep -qxF 'fb-test-999' "$FAKE_DIR/killed"
check test -d "$WT"
check contains "$(cat "$WT/.supervisor.log")" 'reason=done'

# gc: --prune-worktrees prints what it would remove, and removes nothing
fake_session test-999 "$IDLE_PANE"
out=$(bash "$TOOL" --root "$REPO" gc --idle-hours 1 --prune-worktrees --dry-run)
check contains "$out" 'would-stop name=test-999 reason=done'
check contains "$out" 'would-prune name=test-999 cleanup=git worktree remove .worktrees/test-999'
check test -d "$WT"
rm -f "$WT/.agent-result"

# gc: a refused session is stopped, but its worktree is never offered for
# pruning: the branch was never pushed and may hold the only copy of the work
printf 'concurrent-session limit\n' >"$WT/.refusal"
fake_session test-999 "$IDLE_PANE"
out=$(bash "$TOOL" --root "$REPO" gc --idle-hours 1 --prune-worktrees)
check contains "$out" 'stop name=test-999 reason=refused'
check test -z "$(printf '%s\n' "$out" | grep 'cleanup=' || true)"
check test -d "$WT"
check test ! -f "$WT/.refusal"

# gc: a session whose worktree is gone only holds a slot, so plain gc stops
# it; --all is no longer needed to free a merged run
printf 'fb-ghost\n' >"$FAKE_DIR/session"
printf 'Enter a coding task\n' >"$FAKE_DIR/pane"
printf '%s\n' "$(date +%s)" >"$FAKE_DIR/activity"
: >"$FAKE_DIR/killed"
out=$(bash "$TOOL" --root "$REPO" gc --idle-hours 1 --dry-run)
check contains "$out" 'would-stop name=ghost reason=orphan'
check test ! -s "$FAKE_DIR/killed"

out=$(bash "$TOOL" --root "$REPO" gc --idle-hours 1)
check contains "$out" 'stop name=ghost reason=orphan'
check grep -qxF 'fb-ghost' "$FAKE_DIR/killed"
check test -f "$REPO/.worktrees/.orphans.log"
check contains "$(cat "$REPO/.worktrees/.orphans.log")" 'reason=orphan'
# the old flag still parses
printf 'fb-ghost\n' >"$FAKE_DIR/session"
out=$(bash "$TOOL" --root "$REPO" gc --all --idle-hours 1 --dry-run)
check contains "$out" 'would-stop name=ghost reason=orphan'


# ---- session inventory (#11) ----

fake_session test-999 "$IDLE_PANE"
printf 'state=blocked\n' >"$WT/.agent-result"
fake_add_session ghost
# no autostop has been recorded yet: the watcher is `-`, and null in JSON
out=$(bash "$TOOL" --root "$REPO" sessions --no-gh)
check test "$(printf '%s\n' "$out" | awk '$1 == "test-999" { print $4 }')" = -
out=$(bash "$TOOL" --root "$REPO" status --json --no-gh test-999)
check contains "$out" '"watcher": null'
printf 'autostop=pid:%s\n' "$$" >>"$WT/.supervisor.log"

out=$(bash "$TOOL" --root "$REPO" sessions --no-gh)
check contains "$out" 'WORKTREE'
check contains "$out" 'RESULT'
check contains "$out" 'BRANCH'
check test "$(printf '%s\n' "$out" | grep -c '^test-999')" = 1
check test "$(printf '%s\n' "$out" | grep -c '^ghost')" = 1
# columns: NAME STATE IDLE WATCHER WORKTREE RESULT BRANCH
check test "$(printf '%s\n' "$out" | awk '$1 == "ghost" { print $5 }')" = missing
check test "$(printf '%s\n' "$out" | awk '$1 == "test-999" { print $5 }')" = yes
check test "$(printf '%s\n' "$out" | awk '$1 == "test-999" { print $4 }')" = "pid:$$"
check test "$(printf '%s\n' "$out" | awk '$1 == "test-999" { print $6 }')" = blocked
# a live session whose result file is terminal shows no idle (#57)
check test "$(printf '%s\n' "$out" | awk '$1 == "test-999" { print $3 }')" = -
check test "$(printf '%s\n' "$out" | awk '$1 == "ghost" { print $3 }')" != -
check contains "$out" 'sessions=2 running=2 worktrees=1 orphans=1'

# the HOURS column: a live reading, then the ledger with its age, then - (#108)
check contains "$out" 'HOURS'
rm -f "$REPO/.supervisor-hours"
fake_session test-999 "$HOURS_FOOTER_PANE"
out=$(bash "$TOOL" --root "$REPO" sessions --no-gh)
check test "$(printf '%s\n' "$out" | awk '$1 == "test-999" { print $NF }')" = 3/4
printf 'ts=%s hours=1/2 source=panel session=fb-old\n' \
    "$(($(date +%s) - 2820))" >"$REPO/.supervisor-hours"
fake_clear
out=$(bash "$TOOL" --root "$REPO" sessions --no-gh)
check test "$(printf '%s\n' "$out" | awk '$1 == "test-999" { print $(NF-1) }')" = 1/2
check test "$(printf '%s\n' "$out" | awk '$1 == "test-999" { print $NF }')" = age=47m
rm -f "$REPO/.supervisor-hours"
# restore the inventory the next checks read
fake_session test-999 "$IDLE_PANE"
fake_add_session ghost

# the MODEL column and its JSON object: what start recorded at launch (#136)
printf '2026-01-01T00:00:00Z model=DeepSeek V4.1 Flash Fast price=free elapsed=1.2s session=fb-test-999\n' \
    >>"$WT/.supervisor.log"
out=$(bash "$TOOL" --root "$REPO" sessions --no-gh)
check contains "$out" 'MODEL'
check contains "$out" 'DeepSeek V4.1 Flash Fast (free)'
# a row with no recorded model says so, and WAKE/HOURS stay the last two
check test "$(printf '%s\n' "$out" | awk '$1 == "ghost" { print $8 }')" = -
check test "$(printf '%s\n' "$out" | awk '$1 == "test-999" { print $(NF-1) }')" = -
out=$(bash "$TOOL" --root "$REPO" sessions --json --no-gh)
check json_ok "$out"
check contains "$out" '"model": {'
check contains "$out" '"name": "DeepSeek V4.1 Flash Fast",'
check contains "$out" '"hours": "free"'
# status prints the same evidence, and a failed picker attempt is not a model
out=$(bash "$TOOL" --root "$REPO" status --no-gh test-999)
check contains "$out" 'model=DeepSeek V4.1 Flash Fast hours=free'
printf '2026-01-01T00:00:01Z model=no want=flash reason=resolve elapsed=0.1s session=fb-test-999\n' \
    >>"$WT/.supervisor.log"
out=$(bash "$TOOL" --root "$REPO" status --json --no-gh test-999)
check json_ok "$out"
check contains "$out" '"name": "DeepSeek V4.1 Flash Fast",'
# the failed line adds no second model= row: the choice is still the one
out=$(bash "$TOOL" --root "$REPO" status --no-gh test-999)
check test "$(printf '%s\n' "$out" | grep -c '^model=')" = 1

# a watcher that was recorded but has gone is not reported as alive
printf 'autostop=pid:999999\n' >>"$WT/.supervisor.log"
out=$(bash "$TOOL" --root "$REPO" sessions --no-gh)
check test "$(printf '%s\n' "$out" | awk '$1 == "test-999" { print $4 }')" = dead

# list names the orphan, so it cannot be reaped without ever being seen;
# its IDLE column follows the same terminal rule (#57)
out=$(bash "$TOOL" --root "$REPO" list)
check contains "$out" 'orphans=ghost'
check test "$(printf '%s\n' "$out" | awk '$1 == "test-999" { print $6 }')" = -

# even a root with no worktrees reports the orphan instead of only "no worktrees"
mkdir -p "$TMP/no-worktrees"
out=$(bash "$TOOL" --root "$TMP/no-worktrees" list)
check contains "$out" 'no worktrees'
check contains "$out" 'orphans=test-999 ghost'
rm -f "$WT/.agent-result"

# ---- graceful stop (#10) ----

rm -f "$WT/.supervisor.log"
fake_session test-999 "$BUSY_PANE"
printf '%s\n' "$IDLE_PANE" >"$FAKE_DIR/pane_after_escape"
: >"$FAKE_DIR/escaped"
if bash "$TOOL" --root "$REPO" stop test-999 --graceful --wait 5 \
    >"$TMP/stop.out" 2>&1; then rc=0; else rc=$?; fi
check test "$rc" -eq 0
check grep -qxF 'fb-test-999' "$FAKE_DIR/escaped"
check grep -qxF 'fb-test-999' "$FAKE_DIR/killed"
check contains "$(cat "$TMP/stop.out")" 'graceful=escape'
check contains "$(cat "$WT/.supervisor.log")" 'reason=graceful'
check contains "$(cat "$WT/.supervisor.log")" 'interrupted=yes'
check contains "$(cat "$WT/.supervisor.log")" 'pane_state=idle'

# a turn that does not end within the window is left running, not killed
rm -f "$FAKE_DIR/pane_after_escape"
fake_session test-999 "$BUSY_PANE"
if bash "$TOOL" --root "$REPO" stop test-999 --graceful --wait 1 \
    >"$TMP/stop.out" 2>&1; then rc=0; else rc=$?; fi
check test "$rc" -eq 1
check test ! -s "$FAKE_DIR/killed"
check contains "$(cat "$TMP/stop.out")" 'still busy'

# nothing to interrupt when the turn already ended
fake_session test-999 "$IDLE_PANE"
if bash "$TOOL" --root "$REPO" stop test-999 --graceful --wait 1 \
    >"$TMP/stop.out" 2>&1; then rc=0; else rc=$?; fi
check test "$rc" -eq 0
check contains "$(cat "$TMP/stop.out")" 'graceful=already-idle'
check contains "$(cat "$WT/.supervisor.log")" 'interrupted=no'

# the hard stop keeps working and sends nothing
fake_session test-999 "$BUSY_PANE"
: >"$FAKE_DIR/escaped"
out=$(bash "$TOOL" --root "$REPO" stop test-999)
check contains "$out" 'stopped=fb-test-999'
check test ! -s "$FAKE_DIR/escaped"

# ---- capacity before the worktree is spent (#12) ----

fake_session test-999 "$IDLE_PANE"
if bash "$TOOL" --root "$REPO" start --issue 1000 --name test-cap \
    --branch test/cap --title T --url U --max-sessions 1 --no-start \
    >"$TMP/start.out" 2>&1; then rc=0; else rc=$?; fi
check test "$rc" -eq 1
check contains "$(cat "$TMP/start.out")" 'already live'
check test ! -e "$REPO/.worktrees/test-cap"

out=$(bash "$TOOL" --root "$REPO" start --issue 1000 --name test-cap \
    --branch test/cap --title T --url U --max-sessions 1 --dry-run 2>&1)
check contains "$out" 'max_sessions=1 live=1 wait_slot=0'

if bash "$TOOL" --root "$REPO" start --issue 1000 --name test-cap \
    --branch test/cap --title T --url U --max-sessions 1 --wait-slot 0 \
    --no-start >"$TMP/start.out" 2>&1; then rc=0; else rc=$?; fi
check test "$rc" -eq 1
check contains "$(cat "$TMP/start.out")" 'nothing was created'
check test ! -e "$REPO/.worktrees/test-cap"

if bash "$TOOL" --root "$REPO" start --issue 1000 --name test-cap \
    --branch test/cap --title T --url U --wait-slot 5 --no-start \
    >"$TMP/start.out" 2>&1; then rc=0; else rc=$?; fi
check test "$rc" -eq 1
check contains "$(cat "$TMP/start.out")" 'needs --max-sessions'

# a launch that never takes input is stopped; the worktree is kept
if bash "$TOOL" --root "$REPO" start --issue 1001 --name test-dead \
    --branch test/dead --title T --url U >"$TMP/start.out" 2>&1; then rc=0; else rc=$?; fi
check test "$rc" -eq 1
check contains "$(cat "$TMP/start.out")" 'stopped it, worktree kept'
check grep -qxF 'fb-test-dead' "$FAKE_DIR/killed"
check test -d "$REPO/.worktrees/test-dead"
fake_clear

# ---- a finished session still holds a vendor slot (#90) ----

# Freebuff counts live TUIs, not runs, so a done session keeps the
# concurrent-session slot until something stops it. sessions counts those, the
# JSON marks them per row, and a start refused by the overlay names them, so
# the next step is `gc` instead of taking over an unrelated session.
PATH="$TMP/bin:$PATH"
export PATH
export FREEBUFF_BIN="$TMP/bin/freebuff"
: >"$FAKE_DIR/ready"
RESULT_SAVED=''
[ -f "$WT/.agent-result" ] && RESULT_SAVED=$(cat "$WT/.agent-result")
printf 'state=done\n' >"$WT/.agent-result"
fake_session test-999 "$IDLE_PANE"
fake_add_session ghost
out=$(bash "$TOOL" --root "$REPO" sessions --no-gh)
check contains "$out" 'finished=1'
out=$(bash "$TOOL" --root "$REPO" sessions --json --no-gh)
check test "$(printf '%s\n' "$out" | grep -c '"finished": true' || true)" = 1
# every row carries the key; only a live finished one can be true
check test "$(printf '%s\n' "$out" | grep -c '"finished": false' || true)" -ge 1

printf '%s\n' "$REFUSED_PANE" >"$FAKE_DIR/pane"
: >"$FAKE_DIR/sent"
if launch_brief test-refuse-slot 1018 >"$TMP/start.out" 2>&1; then rc=0; else rc=$?; fi
check test "$rc" -ne 0
# ghost has no worktree, so no result file is left to prove its run over;
# its slot is still dead weight and the refusal must name it too (#122)
check contains "$(cat "$TMP/start.out")" 'holding_slot=test-999,ghost'
check contains "$(cat "$TMP/start.out")" 'gc'
check test "$(printf '%s\n' "$(cat "$TMP/start.out")" | grep -c 'holding_slot=' || true)" = 1

# The issue mirrors the session: the launch labels it status:working, and a
# stop moves the label on and comments the evidence. GH_BIN is the fake from
# lib.sh, so this proves the calls without a request leaving the machine.
printf '%s\n' "$IDLE_PANE" >"$FAKE_DIR/pane"
fake_clear
: >"$GH_LOG"
if launch_brief test-gh 1001 >"$TMP/gh-start.out" 2>&1; then rc=0; else rc=$?; fi
check test "$rc" -eq 0
check test -f "$REPO/.worktrees/test-gh/.supervisor-gh"
check contains "$(cat "$REPO/.worktrees/test-gh/.supervisor-gh")" 'issue=1001'
check contains "$(cat "$REPO/.worktrees/test-gh/.supervisor-gh")" 'slug=owner/repo'
check contains "$(cat "$GH_LOG")" 'issue edit 1001'
check contains "$(cat "$GH_LOG")" '--add-label status:working'
check contains "$(cat "$GH_LOG")" 'issue comment 1001'
# One status label at a time: the previous label is removed in the same edit.
printf 'status:working' >"$FAKE_GH_LABELS"
bash "$TOOL" --root "$REPO" stop test-gh >/dev/null 2>&1 || true
check contains "$(cat "$GH_LOG")" '--add-label status:stopped'
check contains "$(cat "$GH_LOG")" '--remove-label status:working'
# No issue, no sync: --no-gh leaves the state file out entirely.
: >"$GH_LOG"
printf '%s\n' "$IDLE_PANE" >"$FAKE_DIR/pane"
launch_brief test-nogh 1002 --no-gh >/dev/null 2>&1 || true
check test ! -f "$REPO/.worktrees/test-nogh/.supervisor-gh"
check test ! -s "$GH_LOG"

# ---- the opt-in Termux wake lock (#99) ----

# The lock is service-scoped, so the tool only ever acquires it: start asks
# once per launch, records the answer, and nothing (least of all stop) releases
# it. Both stubs log, so a release would be visible instead of assumed away.
mkdir -p "$TMP/wake-bin"
cat >"$TMP/wake-bin/termux-wake-lock" <<'FAKE'
#!/usr/bin/env bash
printf 'lock\n' >>"${WAKE_LOG:?}"
FAKE
cat >"$TMP/wake-bin/termux-wake-unlock" <<'FAKE'
#!/usr/bin/env bash
printf 'unlock\n' >>"${UNLOCK_LOG:?}"
FAKE
chmod +x "$TMP/wake-bin/termux-wake-lock" "$TMP/wake-bin/termux-wake-unlock"
: >"$TMP/wake.log"
: >"$TMP/unlock.log"
export WAKE_LOG="$TMP/wake.log" UNLOCK_LOG="$TMP/unlock.log"
PATH_SAVED="$PATH"
export PATH="$TMP/wake-bin:$PATH"

# --wake-lock acquires once and records it, on the launch and in the log.
printf '%s\n' "$IDLE_PANE" >"$FAKE_DIR/pane"
if launch_brief test-wake 1101 --wake-lock >"$TMP/start.out" 2>&1; then rc=0; else rc=$?; fi
check test "$rc" -eq 0
check test "$(grep -c . "$TMP/wake.log")" = 1
check contains "$(cat "$TMP/start.out")" 'wake_lock=acquired'
check contains "$(cat "$REPO/.worktrees/test-wake/.supervisor.log")" 'wake_lock=acquired'

# A second session asks again and releases nothing: the lock it already holds
# belongs to every session and the GUI, not to the first run.
printf '%s\n' "$IDLE_PANE" >"$FAKE_DIR/pane"
if launch_brief test-wake-two 1102 --wake-lock >"$TMP/start.out" 2>&1; then rc=0; else rc=$?; fi
check test "$rc" -eq 0
check test "$(grep -c . "$TMP/wake.log")" = 2
check contains "$(cat "$REPO/.worktrees/test-wake-two/.supervisor.log")" 'wake_lock=acquired'
check test ! -s "$TMP/unlock.log"

# stop never unlocks, even for the session that asked for the lock.
out=$(bash "$TOOL" --root "$REPO" stop test-wake)
check contains "$out" 'stopped=fb-test-wake'
check test ! -s "$TMP/unlock.log"

# status and sessions report what was recorded at start, not a live claim.
out=$(bash "$TOOL" --root "$REPO" status --no-gh test-wake)
check contains "$out" 'wake_lock=acquired'
out=$(bash "$TOOL" --root "$REPO" status --json --no-gh test-wake)
check contains "$out" '"wake_lock": "acquired"'
out=$(bash "$TOOL" --root "$REPO" sessions --no-gh)
check test "$(printf '%s\n' "$out" | awk '$1 == "test-wake" { print $(NF-1) }')" = acquired
check test "$(printf '%s\n' "$out" | awk '$1 == "test-wake-two" { print $(NF-1) }')" = acquired

# FREEBUFF_WAKE_LOCK=1 is the same switch for a shell that always wants it.
: >"$TMP/wake.log"
printf '%s\n' "$IDLE_PANE" >"$FAKE_DIR/pane"
export FREEBUFF_WAKE_LOCK=1
if launch_brief test-wake-env 1103 >"$TMP/start.out" 2>&1; then rc=0; else rc=$?; fi
unset FREEBUFF_WAKE_LOCK
check test "$rc" -eq 0
check test "$(grep -c . "$TMP/wake.log")" = 1
check contains "$(cat "$REPO/.worktrees/test-wake-env/.supervisor.log")" 'wake_lock=acquired'

# Without the binary the run is not blocked: it warns, starts, and records
# unavailable so a later reap has an explanation.
mv "$TMP/wake-bin/termux-wake-lock" "$TMP/wake-lock.stub"
: >"$TMP/wake.log"
printf '%s\n' "$IDLE_PANE" >"$FAKE_DIR/pane"
if launch_brief test-wake-none 1104 --wake-lock >"$TMP/start.out" 2>&1; then rc=0; else rc=$?; fi
mv "$TMP/wake-lock.stub" "$TMP/wake-bin/termux-wake-lock"
check test "$rc" -eq 0
check contains "$(cat "$TMP/start.out")" 'wake_lock=unavailable'
check contains "$(cat "$TMP/start.out")" 'not protected'
check contains "$(cat "$REPO/.worktrees/test-wake-none/.supervisor.log")" 'wake_lock=unavailable'
check test ! -s "$TMP/wake.log"

# A binary that fails is recorded as failed, and the run still starts.
mv "$TMP/wake-bin/termux-wake-lock" "$TMP/wake-lock.stub"
printf '#!/usr/bin/env bash\nexit 3\n' >"$TMP/wake-bin/termux-wake-lock"
chmod +x "$TMP/wake-bin/termux-wake-lock"
printf '%s\n' "$IDLE_PANE" >"$FAKE_DIR/pane"
if launch_brief test-wake-fail 1107 --wake-lock >"$TMP/start.out" 2>&1; then rc=0; else rc=$?; fi
rm -f "$TMP/wake-bin/termux-wake-lock"
mv "$TMP/wake-lock.stub" "$TMP/wake-bin/termux-wake-lock"
check test "$rc" -eq 0
check contains "$(cat "$TMP/start.out")" 'wake_lock=failed'
check contains "$(cat "$TMP/start.out")" 'exited 3'
check contains "$(cat "$REPO/.worktrees/test-wake-fail/.supervisor.log")" 'wake_lock=failed'

# A run without the flag is unchanged: no call and no wake_lock record.
: >"$TMP/wake.log"
printf '%s\n' "$IDLE_PANE" >"$FAKE_DIR/pane"
if launch_brief test-nowake 1105 >"$TMP/start.out" 2>&1; then rc=0; else rc=$?; fi
check test "$rc" -eq 0
check test ! -s "$TMP/wake.log"
check test -z "$(grep -F 'wake_lock=' "$REPO/.worktrees/test-nowake/.supervisor.log" 2>/dev/null || true)"
out=$(bash "$TOOL" --root "$REPO" status --json --no-gh test-nowake)
check contains "$out" '"wake_lock": null'

# The flag is part of the surface, and a dry run names the plan without
# acquiring anything.
check contains "$(bash "$TOOL" --help 2>&1)" '--wake-lock'
out=$(bash "$TOOL" --root "$REPO" start --issue 1106 --name test-wake-dry \
    --branch test/wake-dry --title T --url U --wake-lock --dry-run)
check contains "$out" 'wake_lock=requested'
check test ! -s "$TMP/wake.log"

# Put PATH back so the areas after this one see the fixture they expect.
export PATH="$PATH_SAVED"

# ---- send: the `--` form and a pane with no composer (#121) ----

# `send NAME -- TEXT` used to type the separator itself and drop the message.
# The text arrives as one argv element and nothing else is typed but Enter.
fake_session test-999 "$IDLE_PANE"
: >"$FAKE_DIR/sent"
out=$(bash "$TOOL" --root "$REPO" send test-999 -- '-also a follow-up')
check test -z "$out"
check grep -qF -- $'-also a follow-up\t' "$FAKE_DIR/sent"
check test "$(grep -c . "$FAKE_DIR/sent")" = 2

# A `--` with nothing after it is a missing text, not a message of "--".
: >"$FAKE_DIR/sent"
if bash "$TOOL" --root "$REPO" send test-999 -- >"$TMP/send.out" 2>&1; then rc=0; else rc=$?; fi
check test "$rc" -ne 0
check contains "$(cat "$TMP/send.out")" 'send: TEXT is required'
check test ! -s "$FAKE_DIR/sent"

# A released session has an overlay, not a composer: typing there loses the
# text, so send refuses and names the step that retries the session.
fake_session test-999 "$RELEASED_PANE"
: >"$FAKE_DIR/sent"
if bash "$TOOL" --root "$REPO" send test-999 'continue' >"$TMP/send.out" 2>&1; then rc=0; else rc=$?; fi
check test "$rc" -ne 0
check contains "$(cat "$TMP/send.out")" 'released-session overlay'
check contains "$(cat "$TMP/send.out")" 'press Enter in the pane'
check test ! -s "$FAKE_DIR/sent"

# A detached worktree answers `HEAD`; the launch record keeps the branch the
# session was created on, so a retry does not lose it from the column.
fake_session test-999 "$IDLE_PANE"
printf 'branch=test/recorded\n' >"$WT/.supervisor-gh"
git -C "$WT" checkout --detach >/dev/null 2>&1
check test "$(git -C "$WT" rev-parse --abbrev-ref HEAD)" = HEAD
out=$(bash "$TOOL" --root "$REPO" sessions --no-gh)
check test "$(printf '%s\n' "$out" | awk '$1 == "test-999" { print $7 }')" = test/recorded
# Without the gh record, the branch .task.md was written with is the fallback.
rm -f "$WT/.supervisor-gh"
out=$(bash "$TOOL" --root "$REPO" sessions --no-gh)
check test "$(printf '%s\n' "$out" | awk '$1 == "test-999" { print $7 }')" = test/999
git -C "$WT" checkout test/999 >/dev/null 2>&1

# leave the fixture as it was found
if [ -n "$RESULT_SAVED" ]; then
    printf '%s\n' "$RESULT_SAVED" >"$WT/.agent-result"
else
    rm -f "$WT/.agent-result"
fi
fake_clear
