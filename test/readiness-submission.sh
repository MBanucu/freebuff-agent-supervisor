#!/usr/bin/env bash
# Area: the readiness deadline (#46) and submission proof (#39).

# shellcheck shell=bash
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

# A ready pane on the first check, and a send whose default result is a
# turn in flight; individual checks opt into a slower or stranger pane.
PATH="$TMP/bin:$PATH"
export PATH
export FREEBUFF_BIN="$TMP/bin/freebuff"
rm -f "$FAKE_DIR/ready_after" "$FAKE_DIR/pane_after_send" "$FAKE_DIR/fast_sleep"
: >"$FAKE_DIR/ready"
printf '%s\n' "$IDLE_PANE" >"$FAKE_DIR/pane"
fake_clear

# ---- readiness gate: a deadline, not a fixed 45 s (#46) ----

# The gate's verdict must not depend on the wall clock in a suite: with this
# flag the fake sleep returns at once, so a "cold" launch is a poll count
# instead of a 90 s wait. Without the flag it is the real sleep.
REAL_SLEEP=$(command -v sleep)
cat >"$TMP/bin/sleep" <<FAKE
#!/usr/bin/env bash
if [ -f "\${FAKE_TMUX_DIR:?}/fast_sleep" ]; then exit 0; fi
exec "$REAL_SLEEP" "\$@"
FAKE
chmod +x "$TMP/bin/sleep"
: >"$FAKE_DIR/fast_sleep"

out=$(bash "$TOOL" --root "$REPO" start --issue 1012 --name test-ready-dry \
    --branch test/ready-dry --title T --url U \
    --ready-timeout 30 --ready-poll 0.25 --dry-run)
check contains "$out" 'ready_timeout=30s ready_poll=0.25s'
check contains "$(bash "$TOOL" --help 2>&1)" '--ready-timeout N'
check test ! -e "$REPO/.worktrees/test-ready-dry"
if bash "$TOOL" --root "$REPO" start --issue 1012 --name test-ready-bad \
    --branch test/ready-bad --title T --url U --ready-poll 0 \
    --dry-run >"$TMP/start.out" 2>&1; then rc=0; else rc=$?; fi
check test "$rc" -eq 1
check contains "$(cat "$TMP/start.out")" '--ready-poll must be a positive number'

# The old budget was 90 polls of 0.5 s. A pane that only reports a tty after
# 100 polls used to be killed just before it became ready; the new default
# deadline lets the same launch through, and the wait leaves a trace.
printf '100\n' >"$FAKE_DIR/ready_after"
printf '%s\n' "$IDLE_PANE" >"$FAKE_DIR/pane"
fake_clear
: >"$FAKE_DIR/sent"
if bash "$TOOL" --root "$REPO" start --issue 1013 --name test-slow \
    --branch test/slow --title T --url U >"$TMP/start.out" 2>&1; then rc=0; else rc=$?; fi
check test "$rc" -eq 0
check contains "$(cat "$TMP/start.out")" 'started=yes'
check contains "$(cat "$TMP/start.out")" 'waiting-for-ready=yes'
SLOW_WT="$REPO/.worktrees/test-slow"
check contains "$(cat "$SLOW_WT/.supervisor.log")" 'waiting-for-ready=yes elapsed=45.0s'
check contains "$(cat "$SLOW_WT/.supervisor.log")" \
    'ready=yes elapsed=50.0s timeout=120s poll=0.5s'
check test -s "$FAKE_DIR/sent"
rm -f "$FAKE_DIR/ready_after"
fake_clear

# A pane that stays up but never draws the resting prompt is a hung TUI: the
# wait gives up inside its own timeout, names the flag that raises it, and
# still prints the last pane lines and the elapsed seconds.
printf '%s\n' "$BUSY_PANE" >"$FAKE_DIR/pane"
: >"$FAKE_DIR/killed"
if bash "$TOOL" --root "$REPO" start --issue 1014 --name test-hung \
    --branch test/hung --title T --url U \
    --ready-timeout 5 --ready-poll 0.5 >"$TMP/start.out" 2>&1; then rc=0; else rc=$?; fi
check test "$rc" -eq 1
check contains "$(cat "$TMP/start.out")" 'did not reach raw input'
check contains "$(cat "$TMP/start.out")" '--ready-timeout 5'
check contains "$(cat "$TMP/start.out")" 'after 5.0s'
check contains "$(cat "$TMP/start.out")" '--- last pane lines ---'
check contains "$(cat "$TMP/start.out")" 'thinking...'
check grep -qxF 'fb-test-hung' "$FAKE_DIR/killed"
HUNG_WT="$REPO/.worktrees/test-hung"
check contains "$(cat "$HUNG_WT/.supervisor.log")" \
    'ready=timeout elapsed=5.0s timeout=5s poll=0.5s'
check test -d "$HUNG_WT"

# A warm pane is ready on the first check: no poll is paid and the log has no
# waiting line, only the outcome.
printf '%s\n' "$IDLE_PANE" >"$FAKE_DIR/pane"
fake_clear
if bash "$TOOL" --root "$REPO" start --issue 1015 --name test-warm \
    --branch test/warm --title T --url U \
    --ready-timeout 30 --ready-poll 0.5 >"$TMP/start.out" 2>&1; then rc=0; else rc=$?; fi
check test "$rc" -eq 0
check contains "$(cat "$TMP/start.out")" 'started=yes'
check test -z "$(grep 'waiting-for-ready' "$TMP/start.out" || true)"
WARM_WT="$REPO/.worktrees/test-warm"
check contains "$(cat "$WARM_WT/.supervisor.log")" \
    'ready=yes elapsed=0.0s timeout=30s poll=0.5s'
check test -z "$(grep 'waiting-for-ready' "$WARM_WT/.supervisor.log" || true)"

# ---- the trust prompt (#76) ----

# A worktree with .agents/ stops Freebuff at a plain-terminal prompt before the
# TUI mounts. The resting prompt never appears, so the old readiness wait spent
# the whole timeout; start must name the directory and both ways to proceed on
# the first poll, type nothing and stop the session.
printf '%s\n' "$TRUST_PANE" >"$FAKE_DIR/pane"
fake_clear
if bash "$TOOL" --root "$REPO" start --issue 1020 --name test-trust \
    --branch test/trust --title T --url U \
    --ready-timeout 30 --ready-poll 0.5 >"$TMP/start.out" 2>&1; then rc=0; else rc=$?; fi
check test "$rc" -eq 1
check contains "$(cat "$TMP/start.out")" 'trust_prompt=yes'
check contains "$(cat "$TMP/start.out")" "$REPO/.worktrees/test-trust/.agents"
check contains "$(cat "$TMP/start.out")" 'Answer y once'
check contains "$(cat "$TMP/start.out")" '--trust-agents'
check contains "$(cat "$TMP/start.out")" '--- pane lines the check read ---'
check contains "$(cat "$TMP/start.out")" 'Load and run these?'
check contains "$(cat "$TMP/start.out")" 'sent=no'
check test ! -s "$FAKE_DIR/sent"
check grep -qxF 'fb-test-trust' "$FAKE_DIR/killed"
TRUST_WT="$REPO/.worktrees/test-trust"
check test -d "$TRUST_WT"
check contains "$(cat "$TRUST_WT/.supervisor.log")" \
    'ready=trust-prompt elapsed=0.0s timeout=30s poll=0.5s'
# The verdict lands on the first check, not after the deadline.
check test -z "$(grep 'waiting-for-ready' "$TMP/start.out" || true)"
# The default launch does not pre-answer the gate.
check test -z "$(grep -F -- '--trust-agents' "$FAKE_DIR/launch" || true)"

# The flag is opt-in: a pane without the prompt launches as before, and the
# command handed to tmux carries --trust-agents only when it was asked for.
printf '%s\n' "$IDLE_PANE" >"$FAKE_DIR/pane"
fake_clear
if bash "$TOOL" --root "$REPO" start --issue 1021 --name test-trust-flag \
    --branch test/trust-flag --title T --url U --trust-agents \
    --ready-timeout 30 --ready-poll 0.5 >"$TMP/start.out" 2>&1; then rc=0; else rc=$?; fi
check test "$rc" -eq 0
check contains "$(cat "$TMP/start.out")" 'started=yes'
check contains "$(cat "$FAKE_DIR/launch")" '--trust-agents'

out=$(bash "$TOOL" --root "$REPO" start --issue 1022 --name test-trust-dry \
    --branch test/trust-dry --title T --url U --dry-run)
check contains "$out" 'trust_agents=no'
out=$(bash "$TOOL" --root "$REPO" start --issue 1022 --name test-trust-dry \
    --branch test/trust-dry --title T --url U --trust-agents --dry-run)
check contains "$out" 'trust_agents=yes'
check contains "$(bash "$TOOL" --help 2>&1)" '--trust-agents'

# ---- submission proof: the Enter is not proof (#39) ----

# Accepted: the composer clears and the turn is in flight. Exactly one
# literal send and one Enter are typed, and the proof is recorded.
printf '%s\n' "$IDLE_PANE" >"$FAKE_DIR/pane"
fake_clear
: >"$FAKE_DIR/sent"
if bash "$TOOL" --root "$REPO" start --issue 1016 --name test-proof-ok \
    --branch test/proof-ok --title T --url U --ready-timeout 30 \
    --ready-poll 0.5 --submit-timeout 5 >"$TMP/start.out" 2>&1; then rc=0; else rc=$?; fi
check test "$rc" -eq 0
check contains "$(cat "$TMP/start.out")" 'sent=yes'
check contains "$(cat "$TMP/start.out")" 'submit_proof=turn-began'
check contains "$(cat "$TMP/start.out")" 'started=yes'
check test "$(grep -c -- '-l' "$FAKE_DIR/sent")" = 1
check test "$(grep -c 'C-m' "$FAKE_DIR/sent")" = 1
check test -z "$(grep 'resent=yes' "$TMP/start.out" || true)"
check contains "$(cat "$REPO/.worktrees/test-proof-ok/.supervisor.log")" \
    'submit=yes proof=turn-began'

# A changed chat title is the other proof: the brief was consumed even before
# the busy chrome is drawn, so the launch is reported as sent.
printf '%s\n' "$IDLE_PANE" >"$FAKE_DIR/pane"
printf '%s\n' "$TITLE_ONLY_PANE" >"$FAKE_DIR/pane_after_send"
fake_clear
: >"$FAKE_DIR/sent"
if bash "$TOOL" --root "$REPO" start --issue 1017 --name test-proof-title \
    --branch test/proof-title --title T --url U --ready-timeout 30 \
    --ready-poll 0.5 --submit-timeout 5 >"$TMP/start.out" 2>&1; then rc=0; else rc=$?; fi
check test "$rc" -eq 0
check contains "$(cat "$TMP/start.out")" 'sent=yes'
check contains "$(cat "$TMP/start.out")" 'submit_proof=chat-title'
check test "$(grep -c -- '-l' "$FAKE_DIR/sent")" = 1
check test "$(grep -c 'C-m' "$FAKE_DIR/sent")" = 1

# Swallowed: the composer clears but no turn begins and the title is
# unchanged. start must say sent=no, show the pane it read, stop the
# half-started session, exit non-zero and never retype the brief.
printf '%s\n' "$IDLE_PANE" >"$FAKE_DIR/pane"
printf '%s\n' "$SWALLOWED_PANE" >"$FAKE_DIR/pane_after_send"
fake_clear
: >"$FAKE_DIR/sent"
: >"$FAKE_DIR/killed"
if bash "$TOOL" --root "$REPO" start --issue 1018 --name test-proof-swallow \
    --branch test/proof-swallow --title T --url U --ready-timeout 30 \
    --ready-poll 0.5 --submit-timeout 2 >"$TMP/start.out" 2>&1; then rc=0; else rc=$?; fi
check test "$rc" -ne 0
check contains "$(cat "$TMP/start.out")" 'sent=no'
check contains "$(cat "$TMP/start.out")" 'submit_proof=none'
check contains "$(cat "$TMP/start.out")" 'resent=no'
check contains "$(cat "$TMP/start.out")" '--- pane lines the check read ---'
check contains "$(cat "$TMP/start.out")" 'Enter a coding task'
check test -z "$(grep 'started=yes' "$TMP/start.out" || true)"
check test "$(grep -c -- '-l' "$FAKE_DIR/sent")" = 1
check test "$(grep -c 'C-m' "$FAKE_DIR/sent")" = 1
check grep -qxF 'fb-test-proof-swallow' "$FAKE_DIR/killed"
check contains "$(cat "$REPO/.worktrees/test-proof-swallow/.supervisor.log")" \
    'submit=no elapsed=2.0s timeout=2s'
check test -d "$REPO/.worktrees/test-proof-swallow"
# Nobody saw the swallowed text, so the ledger does not block a deliberate
# retry with the same brief.
check test -z "$(grep -F 'test-proof-swallow' "$REPO/.supervisor-briefs.jsonl" || true)"

# An Enter that never arrived leaves the brief in the input line: that is not
# submission either, and it is reported the same way.
printf '%s\n' "$IDLE_PANE" >"$FAKE_DIR/pane"
printf '%s\n' "$TYPED_PANE" >"$FAKE_DIR/pane_after_send"
fake_clear
: >"$FAKE_DIR/sent"
: >"$FAKE_DIR/killed"
if bash "$TOOL" --root "$REPO" start --issue 1019 --name test-proof-typed \
    --branch test/proof-typed --title T --url U --ready-timeout 30 \
    --ready-poll 0.5 --submit-timeout 2 >"$TMP/start.out" 2>&1; then rc=0; else rc=$?; fi
check test "$rc" -ne 0
check contains "$(cat "$TMP/start.out")" 'sent=no'
check contains "$(cat "$TMP/start.out")" 'submit_proof=none'
check contains "$(cat "$TMP/start.out")" 'Read the file .task.md'
check test "$(grep -c -- '-l' "$FAKE_DIR/sent")" = 1
check grep -qxF 'fb-test-proof-typed' "$FAKE_DIR/killed"
fake_clear
rm -f "$FAKE_DIR/fast_sleep"
fake_clear
