#!/usr/bin/env bash
# Area: the completion result file, state classification, --explain and the
# terminal-idle rule (#57).

# shellcheck shell=bash
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

# No session and no result: this area starts from a settled worktree.
[ -d "$WT" ] || bash "$TOOL" --root "$REPO" start --issue 999 --name test-999 \
    --branch test/999 --title 'Test issue' \
    --url 'https://example.test/issues/999' --no-start >/dev/null
rm -f "$WT/.agent-result" "$WT/.refusal"
fake_clear

# ---- completion result file (#2) ----

out=$(bash "$TOOL" --root "$REPO" status --no-gh test-999)
check contains "$out" 'state=unknown'

printf 'state=done\npr=https://example.test/pr/1\ncommit=abc1234\ntests=ok 12 checks\n' \
    >"$WT/.agent-result"
out=$(bash "$TOOL" --root "$REPO" status --no-gh test-999)
check contains "$out" 'state=done'
check contains "$out" 'result_pr=https://example.test/pr/1'
check contains "$out" 'result_commit=abc1234'
check contains "$out" 'result_tests=ok 12 checks'
check test -z "$(git -C "$WT" status --short)"

printf 'state=bogus\n' >"$WT/.agent-result"
out=$(bash "$TOOL" --root "$REPO" status --no-gh test-999)
check contains "$out" 'state=unknown'
rm -f "$WT/.agent-result"

fake_session test-999 "$IDLE_PANE" "$(($(date +%s) - 30))"
out=$(bash "$TOOL" --root "$REPO" status --no-gh test-999)
check contains "$out" 'running=yes'
check contains "$out" 'session_state=idle'
check contains "$out" 'idle_seconds='

out=$(bash "$TOOL" --root "$REPO" list)
check contains "$out" 'STATE'
check contains "$out" 'test-999'
check contains "$out" 'idle'

# watch: idle pane ends the watch
if bash "$TOOL" --root "$REPO" watch test-999 --idle-seconds 0 --poll 0 \
    --timeout 10 >"$TMP/watch.out" 2>&1; then rc=0; else rc=$?; fi
check test "$rc" -eq 0
check contains "$(cat "$TMP/watch.out")" 'state=idle'

# watch: busy pane runs into the timeout
fake_session test-999 "$BUSY_PANE"
if bash "$TOOL" --root "$REPO" watch test-999 --timeout 1 --poll 1 \
    >"$TMP/watch.out" 2>&1; then rc=0; else rc=$?; fi
check test "$rc" -eq 1
check contains "$(cat "$TMP/watch.out")" 'state=working'
check contains "$(cat "$TMP/watch.out")" 'state=timeout'

# watch: a refused session is not reported as finished
fake_session test-999 "$REFUSED_PANE"
if bash "$TOOL" --root "$REPO" watch test-999 --timeout 1 --poll 1 \
    >"$TMP/watch.out" 2>&1; then rc=0; else rc=$?; fi
check test "$rc" -eq 1
check contains "$(cat "$TMP/watch.out")" 'state=refused'

# a refusal in the turn text above the resting prompt is refused, not idle
fake_session test-999 "$STRIKE_PANE"
out=$(bash "$TOOL" --root "$REPO" status --no-gh test-999)
check contains "$out" 'session_state=refused'
if bash "$TOOL" --root "$REPO" watch test-999 --timeout 1 --poll 1 \
    >"$TMP/watch.out" 2>&1; then rc=0; else rc=$?; fi
check test "$rc" -eq 1
check contains "$(cat "$TMP/watch.out")" 'state=refused'

# the account budget line is refusal vocabulary too
fake_session test-999 "$BUDGET_PANE"
out=$(bash "$TOOL" --root "$REPO" status --no-gh test-999)
check contains "$out" 'session_state=refused'

# a pane no rule can classify is unknown, not working
fake_session test-999 "$NOMARKER_PANE"
out=$(bash "$TOOL" --root "$REPO" status --no-gh test-999)
check contains "$out" 'session_state=unknown'

# --explain names the decision, every marker it checked and the pane it read
out=$(bash "$TOOL" --root "$REPO" status --no-gh --explain test-999)
check contains "$out" 'session_state=unknown'
check contains "$out" 'explain: rule=no-rule-matched'
check contains "$out" 'explain: no rule matched the window'
check contains "$out" 'explain: check: refusal-prose'
check contains "$out" 'explain: check: busy-marker'
check contains "$out" 'explain: check: resting-prompt'
check contains "$out" 'explain: check: protected-window'
check contains "$out" 'explain: check: stable-window: yes'
check contains "$out" 'explain: stable_scans=2'
check contains "$out" 'explain: window=3 lines sha256='
check contains "$out" 'explain: pane:'
check contains "$out" '⎘ • 6s • △▽'
# a known state names the rule that won and the line it matched
fake_session test-999 "$IDLE_PANE"
out=$(bash "$TOOL" --root "$REPO" status --no-gh --explain test-999)
check contains "$out" 'session_state=idle'
check contains "$out" 'explain: rule=resting-prompt'
check contains "$out" 'explain: matched='
check contains "$out" 'Enter a coding task'
check contains "$out" 'explain: stable_scans=1'
check contains "$out" 'explain: pane:'
fake_session test-999 "$BUSY_PANE"
out=$(bash "$TOOL" --root "$REPO" status --no-gh --explain test-999)
check contains "$out" 'session_state=working'
check contains "$out" 'explain: rule=busy-marker'
check contains "$out" 'thinking...'
check contains "$out" 'explain: check: busy-marker pattern='
fake_session test-999 "$APPROVAL_PANE"
out=$(bash "$TOOL" --root "$REPO" status --no-gh --explain test-999)
check contains "$out" 'session_state=working'
check contains "$out" 'explain: rule=protected-window'
fake_session test-999 "$STRIKE_PANE"
out=$(bash "$TOOL" --root "$REPO" status --no-gh --explain test-999)
check contains "$out" 'session_state=refused'
check contains "$out" 'explain: rule=refusal-prose'
printf 'state=done\npr=none\n' >"$WT/.agent-result"
out=$(bash "$TOOL" --root "$REPO" status --no-gh --explain test-999)
check contains "$out" 'session_state=done'
check contains "$out" 'explain: rule=result-file'
# blocked and failed are the result file's own state, not another done. A
# wait contract reads watch's exit status: 3 for blocked, 4 for failed.
for want in blocked failed; do
    printf 'state=%s\npr=none\n' "$want" >"$WT/.agent-result"
    out=$(bash "$TOOL" --root "$REPO" status --no-gh test-999)
    check contains "$out" "session_state=$want"
    out=$(bash "$TOOL" --root "$REPO" status --json --no-gh test-999)
    check contains "$out" "\"session_state\": \"$want\""
    case "$want" in
        blocked) want_rc=3 ;;
        failed) want_rc=4 ;;
    esac
    if bash "$TOOL" --root "$REPO" watch test-999 --timeout 5 --poll 1 \
        >"$TMP/watch.out" 2>&1; then rc=0; else rc=$?; fi
    check test "$rc" -eq "$want_rc"
    check contains "$(cat "$TMP/watch.out")" "state=$want"
done
rm -f "$WT/.agent-result"
fake_clear
out=$(bash "$TOOL" --root "$REPO" status --no-gh --explain test-999)
check contains "$out" 'session_state=missing'
check contains "$out" 'explain: rule=no-session'

# the unknown window survives two scans and a repaint with new spacing/time
fake_session test-999 "$NOMARKER_PANE"
out=$(bash "$TOOL" --root "$REPO" status --json --no-gh test-999)
check json_ok "$out"
check contains "$out" '"session_state": "unknown"'
check contains "$out" '"rule": "no-rule-matched"'
check contains "$out" '"stable_scans": 2'
sha1=$(printf '%s\n' "$out" |
    sed -n 's/.*"window_sha256": "\([0-9a-f]*\)".*/\1/p')
out=$(bash "$TOOL" --root "$REPO" status --json --no-gh test-999)
sha2=$(printf '%s\n' "$out" |
    sed -n 's/.*"window_sha256": "\([0-9a-f]*\)".*/\1/p')
check test -n "$sha1"
check test "$sha1" = "$sha2"
fake_session test-999 '⎘ • 9s • △▽
╭──────────────────╮
│      ▍Add to the current task (/ for commands)'
out=$(bash "$TOOL" --root "$REPO" status --json --no-gh test-999)
sha3=$(printf '%s\n' "$out" |
    sed -n 's/.*"window_sha256": "\([0-9a-f]*\)".*/\1/p')
check contains "$out" '"session_state": "unknown"'
check test "$sha3" = "$sha1"

# an unknown pane is watched, not reaped
if bash "$TOOL" --root "$REPO" watch test-999 --timeout 1 --poll 1 \
    >"$TMP/watch.out" 2>&1; then rc=0; else rc=$?; fi
check test "$rc" -eq 1
check contains "$(cat "$TMP/watch.out")" 'state=unknown'
fake_session test-999 "$NOMARKER_PANE"
out=$(bash "$TOOL" --root "$REPO" gc --idle-hours 1 --dry-run)
check contains "$out" 'skip name=test-999 reason=unknown'
check test ! -s "$FAKE_DIR/killed"

# watch: an approval prompt is not idle
fake_session test-999 "$APPROVAL_PANE"
if bash "$TOOL" --root "$REPO" watch test-999 --timeout 1 --poll 1 \
    >"$TMP/watch.out" 2>&1; then rc=0; else rc=$?; fi
check test "$rc" -eq 1
check contains "$(cat "$TMP/watch.out")" 'state=working'

# a banner above the resting prompt must not pin the session at working
fake_session test-999 "$BANNER_IDLE_PANE"
out=$(bash "$TOOL" --root "$REPO" status --no-gh test-999)
check contains "$out" 'session_state=idle'
if bash "$TOOL" --root "$REPO" watch test-999 --idle-seconds 0 --poll 0 \
    --timeout 10 >"$TMP/watch.out" 2>&1; then rc=0; else rc=$?; fi
check test "$rc" -eq 0
check contains "$(cat "$TMP/watch.out")" 'state=idle'

# the same banner with a turn in flight is still working
fake_session test-999 "$BANNER_BUSY_PANE"
if bash "$TOOL" --root "$REPO" watch test-999 --timeout 1 --poll 1 \
    >"$TMP/watch.out" 2>&1; then rc=0; else rc=$?; fi
check test "$rc" -eq 1
check contains "$(cat "$TMP/watch.out")" 'state=working'

# prose that mentions a permission at the rendered prompt is idle
fake_session test-999 "$PROSE_AT_PROMPT_PANE"
out=$(bash "$TOOL" --root "$REPO" status --no-gh test-999)
check contains "$out" 'session_state=idle'

# watch: the result file wins over a busy pane
printf 'state=done\npr=none\n' >"$WT/.agent-result"
fake_session test-999 "$BUSY_PANE"
if bash "$TOOL" --root "$REPO" watch test-999 --timeout 5 --poll 1 \
    >"$TMP/watch.out" 2>&1; then rc=0; else rc=$?; fi
check test "$rc" -eq 0
check contains "$(cat "$TMP/watch.out")" 'state=done'
rm -f "$WT/.agent-result"

# watch: missing session
fake_clear
if bash "$TOOL" --root "$REPO" watch test-999 --timeout 2 --poll 1 \
    >"$TMP/watch.out" 2>&1; then rc=0; else rc=$?; fi
check test "$rc" -eq 2
check contains "$(cat "$TMP/watch.out")" 'state=missing'

# ---- idle only while a session can be idle (#57) ----

# done, blocked and failed are all terminal: the result file outranks the
# pane, so a live TUI at the resting prompt must not report an idle time.
fake_session test-999 "$IDLE_PANE" "$(($(date +%s) - 5495))"
for result in done blocked failed; do
    printf 'state=%s\n' "$result" >"$WT/.agent-result"
    out=$(bash "$TOOL" --root "$REPO" status --json --no-gh test-999)
    check json_ok "$out"
    check contains "$out" "\"state\": \"$result\""
    check contains "$out" '"idle_seconds": null'
    out=$(bash "$TOOL" --root "$REPO" status --no-gh test-999)
    check contains "$out" "state=$result"
    check test "$(printf '%s\n' "$out" | grep -c '^idle_seconds=')" = 0
    out=$(bash "$TOOL" --root "$REPO" sessions --json --no-gh)
    check test "$(printf '%s\n' "$out" | grep -c '"idle_seconds": null')" = 1
    out=$(bash "$TOOL" --root "$REPO" sessions --no-gh)
    check test "$(printf '%s\n' "$out" | awk '$1 == "test-999" { print $3 }')" = -
done

# resuming a session makes it idle again: the same 5495-second activity
# delta is reported once the result file no longer claims the run is over.
rm -f "$WT/.agent-result"
out=$(bash "$TOOL" --root "$REPO" status --json --no-gh test-999)
check contains "$out" '"state": "unknown"'
check contains "$out" '"session_state": "idle"'
check test "$(printf '%s\n' "$out" | grep -c '"idle_seconds": [0-9]')" = 1
out=$(bash "$TOOL" --root "$REPO" status --no-gh test-999)
check contains "$out" 'idle_seconds='
out=$(bash "$TOOL" --root "$REPO" sessions --json --no-gh)
check test "$(printf '%s\n' "$out" | grep -c '"idle_seconds": null')" = 0

# a session that is gone is running=false with a null pane, not a missing key
fake_clear
out=$(bash "$TOOL" --root "$REPO" status --json --no-gh test-999)
check json_ok "$out"
check contains "$out" '"running": false'
check contains "$out" '"session_state": "missing"'
check contains "$out" '"pane": null'

fake_session test-999 "$IDLE_PANE"
rm -f "$WT/.agent-result"

# ---- the Concord source (#68) ----
# The export is a fixture: no Concord install, MCP client or network is
# involved. It is the shape Concord writes (generated_at, presence, tasks),
# pretty-printed one key per line.
CONCORD="$WT/.concord/WORK_STATE.json"
concord_work_state() {
    # concord_work_state STATUS [BRANCH] -> one task in a WORK_STATE.json
    local status=$1 branch=${2:-test/999}
    mkdir -p "$WT/.concord"
    # Concord's setup writes this, so the export keeps the worktree clean.
    printf '*\n' >"$WT/.concord/.gitignore"
    cat >"$CONCORD" <<EOF
{
  "generated_at": "2026-11-27T10:00:00.000Z",
  "presence": [],
  "tasks": [
    {
      "task_id": "T68",
      "title": "concord source",
      "status": "$status",
      "agent": "codex",
      "agent_id": "codex:t68",
      "assigned_agent_id": null,
      "version": 3,
      "updated_at": "2026-11-27T10:00:00.000Z",
      "lease_expires_at": null,
      "owner": null,
      "branch": "$branch",
      "parent_task_id": null,
      "modules": [],
      "domains": [],
      "expected_files": []
    }
  ]
}
EOF
}

# Every reported status maps to one session_state and is read without a pane:
# no tmux session exists for this loop, so only the file can answer.
fake_clear
for pair in active:working assigned:working handoff_offered:working \
    blocked:blocked review_ready:done handed_off:done complete:done closed:done; do
    cstatus=${pair%%:*}
    want=${pair#*:}
    concord_work_state "$cstatus"
    out=$(bash "$TOOL" --root "$REPO" status --no-gh --source concord test-999)
    check contains "$out" "session_state=$want"
    check contains "$out" "concord_status=$cstatus"
    check contains "$out" "concord_task=T68"
done

# A status that is not a run signal is unknown with the reason, never working.
concord_work_state proposed
out=$(bash "$TOOL" --root "$REPO" status --no-gh --source concord --explain test-999)
check contains "$out" 'session_state=unknown'
check contains "$out" 'explain: rule=concord-unknown-status'
check contains "$out" 'concord=unknown-status'

# A branch selects the worktree's task in the shared workspace: the older
# blocked task on another branch does not win.
mkdir -p "$WT/.concord"
printf '*\n' >"$WT/.concord/.gitignore"
cat >"$CONCORD" <<'EOF'
{
  "generated_at": "2026-11-27T10:00:00.000Z",
  "presence": [],
  "tasks": [
    {
      "task_id": "T-other",
      "status": "blocked",
      "version": 9,
      "updated_at": "2026-11-27T11:00:00.000Z",
      "branch": "feat/other"
    },
    {
      "task_id": "T-mine",
      "status": "active",
      "version": 1,
      "updated_at": "2026-11-27T09:00:00.000Z",
      "branch": "test/999"
    }
  ]
}
EOF
out=$(bash "$TOOL" --root "$REPO" status --no-gh --source concord test-999)
check contains "$out" 'session_state=working'
check contains "$out" 'concord_task=T-mine'

# Both sources present and disagreeing: auto chooses Concord and prints the
# losing pane verdict, while the default pane view ignores Concord entirely.
concord_work_state active
fake_session test-999 "$IDLE_PANE"
out=$(bash "$TOOL" --root "$REPO" status --no-gh --source auto --explain test-999)
check contains "$out" 'session_state=working'
check contains "$out" 'explain: source=concord'
check contains "$out" 'explain: loser=pane'
check contains "$out" 'explain: loser_state=idle'
out=$(bash "$TOOL" --root "$REPO" status --no-gh --source concord --explain test-999)
check contains "$out" 'session_state=working'
check contains "$out" 'explain: source=concord'
check contains "$out" 'explain: loser_state=idle'
out=$(bash "$TOOL" --root "$REPO" status --no-gh --source pane test-999)
check contains "$out" 'session_state=idle'
check test -z "$(printf '%s\n' "$out" | grep -F 'concord_status=' || true)"

# Missing and corrupt exports fall back to the pane for auto, with a reason
# line; never an accidental unknown, and no write to the worktree.
rm -rf "$WT/.concord"
out=$(bash "$TOOL" --root "$REPO" status --no-gh --source auto --explain test-999)
check contains "$out" 'session_state=idle'
check contains "$out" 'concord=missing'
check contains "$out" 'explain: source=pane'
check contains "$out" 'explain: check: concord-verdict: missing'
check test ! -e "$WT/.concord"

mkdir -p "$WT/.concord"
printf '{"tasks": [\n' >"$CONCORD"
fake_session test-999 "$BUSY_PANE"
out=$(bash "$TOOL" --root "$REPO" status --no-gh --source auto test-999)
check contains "$out" 'session_state=working'
check contains "$out" 'concord=corrupt'
out=$(bash "$TOOL" --root "$REPO" status --no-gh --source concord --explain test-999)
check contains "$out" 'session_state=unknown'
check contains "$out" 'explain: rule=concord-corrupt'
check contains "$out" 'explain: concord=corrupt'

# With no pane either, auto still reports the pane's missing, not unknown.
fake_clear
rm -rf "$WT/.concord"
out=$(bash "$TOOL" --root "$REPO" status --no-gh --source auto --explain test-999)
check contains "$out" 'session_state=missing'
check contains "$out" 'explain: rule=no-session'
check contains "$out" 'concord=missing'

# The result file outranks every source, Concord included.
fake_session test-999 "$IDLE_PANE"
concord_work_state active
printf 'state=done\npr=none\n' >"$WT/.agent-result"
out=$(bash "$TOOL" --root "$REPO" status --no-gh --source concord test-999)
check contains "$out" 'session_state=done'
rm -f "$WT/.agent-result"

# --json carries the source and the Concord fields additively. The evidence
# block names the source and, on a disagreement, the losing pane verdict.
concord_work_state blocked
out=$(bash "$TOOL" --root "$REPO" status --json --no-gh --source concord test-999)
check json_ok "$out"
check contains "$out" '"session_state": "blocked"'
check contains "$out" '"concord_status": "blocked"'
check contains "$out" '"concord_task": "T68"'
check contains "$out" '"concord_reason": "task"'
check contains "$out" '"source": "concord"'
concord_work_state active
fake_session test-999 "$IDLE_PANE"
out=$(bash "$TOOL" --root "$REPO" status --json --no-gh --source concord test-999)
check json_ok "$out"
check contains "$out" '"loser": "pane"'
check contains "$out" '"loser_state": "idle"'
out=$(bash "$TOOL" --root "$REPO" status --json --no-gh test-999)
check json_ok "$out"
check contains "$out" '"session_state": "idle"'
check contains "$out" '"concord_status": null'
check contains "$out" '"concord_reason": null'
check contains "$out" '"source": "pane"'

# sessions --source drives the inventory the GUI renders; its JSON says which
# source produced STATE.
concord_work_state blocked
out=$(bash "$TOOL" --root "$REPO" sessions --json --no-gh --source concord)
check json_ok "$out"
check contains "$out" '"state": "blocked"'
check contains "$out" '"source": "concord"'
if bash "$TOOL" --root "$REPO" sessions --source bogus \
    >"$TMP/sessions-bogus.out" 2>&1; then rc=0; else rc=$?; fi
check test "$rc" -ne 0
check contains "$(cat "$TMP/sessions-bogus.out")" '--source must be pane, concord or auto'

# Leave no Concord fixture for the areas that run after this one.
rm -rf "$WT/.concord"
rm -f "$WT/.agent-result"
fake_session test-999 "$IDLE_PANE"
