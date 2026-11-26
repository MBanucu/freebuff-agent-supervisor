#!/usr/bin/env bash
# Device-free checks for spawn-freebuff-agent. A temporary git repo stands in
# for the project; a fake tmux stands in for sessions, so no Freebuff, gh,
# network or phone is needed.
set -euo pipefail

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd) || exit 1
TOOL="$ROOT/spawn-freebuff-agent"
TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT

REPO="$TMP/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email test@example.invalid
git -C "$REPO" config user.name Test
git -C "$REPO" config commit.gpgsign false
printf 'hello\n' >"$REPO/README.md"
git -C "$REPO" add README.md
git -C "$REPO" commit -qm init
git -C "$REPO" branch -M main

total=0
failed=0

check() {
    total=$((total + 1))
    if "$@"; then
        return 0
    fi
    failed=$((failed + 1))
    printf 'FAIL %s\n' "$*" >&2
}

contains() {
    # contains <text> <needle>
    printf '%s' "$1" | grep -qF -- "$2"
}

json_ok() {
    # json_ok <text> -> 0 when it parses as JSON. Without python3, fall back to
    # the shape the emitters promise plus the absence of raw tab/CR bytes, so
    # the check still means something on a bare phone.
    local text=${1-}
    if command -v python3 >/dev/null 2>&1; then
        printf '%s' "$text" | python3 -m json.tool >/dev/null 2>&1
        return
    fi
    case "$text" in
        '['*']'|'{'*'}') ;;
        *) return 1 ;;
    esac
    ! printf '%s' "$text" | LC_ALL=C grep -q $'[\t\r]'
}

out=$(bash "$TOOL" --root "$REPO" start --issue 999 --name test-999 \
    --branch test/999 --title 'Test issue' \
    --url 'https://example.test/issues/999' --dry-run)

check contains "$out" "worktree=$REPO/.worktrees/test-999"
check contains "$out" "-x 180 -y 55"
check contains "$out" "result=$REPO/.worktrees/test-999/.agent-result"
check test ! -e "$REPO/.worktrees/test-999"

out=$(bash "$TOOL" --root "$REPO" start --issue 997 --name test-dry \
    --branch test/dry --title 'Dry issue' --url 'https://example.test/997' \
    --auto-stop --dry-run)
check contains "$out" 'autostop=yes idle_seconds=120 poll=5'
check test ! -e "$REPO/.worktrees/test-dry"

# start --prompt replaces the default brief; the flag must be accepted
out=$(bash "$TOOL" --root "$REPO" start --issue 996 --name test-prompt \
    --branch test/prompt --title 'Prompt issue' --url 'https://example.test/996' \
    --prompt 'custom brief' --dry-run)
check contains "$out" 'session=fb-test-prompt'
check test ! -e "$REPO/.worktrees/test-prompt"
check contains "$(bash "$TOOL" --help 2>&1)" '--prompt TEXT'

bash "$TOOL" --root "$REPO" start --issue 999 --name test-999 \
    --branch test/999 --title 'Test issue' \
    --url 'https://example.test/issues/999' --no-start --sdk-dir "$TMP/sdk" >/dev/null

WT="$REPO/.worktrees/test-999"
check test -d "$WT"
check test -f "$WT/.task.md"
check contains "$(cat "$WT/.task.md")" 'issue #999'
check contains "$(cat "$WT/.task.md")" 'test/999'
check contains "$(cat "$WT/.task.md")" '.agent-result'
check contains "$(cat "$WT/.task.md")" 'state=blocked'
check test -f "$WT/local.properties"
check contains "$(cat "$WT/local.properties")" "sdk.dir=$TMP/sdk"
check test "$(git -C "$WT" branch --show-current)" = test/999
check test -z "$(git -C "$WT" status --short)"

check grep -qxF '.task.md' "$REPO/.git/info/exclude"
check grep -qxF 'local.properties' "$REPO/.git/info/exclude"
check grep -qxF '.worktrees/' "$REPO/.git/info/exclude"
check grep -qxF '.agent-result' "$REPO/.git/info/exclude"
check grep -qxF '.supervisor.log' "$REPO/.git/info/exclude"

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

# ---- fake tmux for lifecycle checks (#3, #4) ----

FAKE_DIR="$TMP/fake"
mkdir -p "$FAKE_DIR" "$TMP/bin"
: >"$FAKE_DIR/tty"
: >"$FAKE_DIR/killed"
: >"$FAKE_DIR/escaped"
: >"$FAKE_DIR/sent"
cat >"$TMP/bin/tmux" <<'FAKE'
#!/usr/bin/env bash
d=${FAKE_TMUX_DIR:?}
case "${1:-}" in
    has-session)
        grep -qxF -- "${3:-}" "$d/session" 2>/dev/null
        ;;
    capture-pane)
        cat "$d/pane" 2>/dev/null || true
        ;;
    display-message)
        fmt="${!#}"
        case "$fmt" in
            *pane_tty*)
                # Opt-in: ready_after N makes the pane report no tty for N
                # checks, so a cold launch can be simulated as a poll count
                # instead of a real 45-second wait.
                if [ -f "$d/ready_after" ]; then
                    left=$(cat "$d/ready_after" 2>/dev/null || printf '0')
                    if [ "$left" -gt 0 ]; then
                        printf '%s\n' "$((left - 1))" >"$d/ready_after"
                        exit 0
                    fi
                    rm -f "$d/ready_after"
                fi
                printf '%s\n' "$d/tty"
                ;;
            *session_activity*) cat "$d/activity" 2>/dev/null || printf '0\n' ;;
            *) printf '0\n' ;;
        esac
        ;;
    send-keys)
        if [ "${!#}" = Escape ]; then
            printf '%s\n' "${3:-}" >>"$d/escaped"
            if [ -f "$d/pane_after_escape" ]; then
                mv "$d/pane_after_escape" "$d/pane"
            fi
        else
            # One tab-separated line per call, so a test can prove that a
            # literal text arrived as a single argument instead of being
            # split by a shell.
            line=''
            for arg in "$@"; do line+="$arg"$'\t'; done
            printf '%s\n' "$line" >>"$d/sent"
            # A refusal that arrives as a finished turn: the pane is healthy
            # when start checks readiness, then carries the sentence after
            # the Enter that submitted the brief.
            if [ "${!#}" = C-m ] && [ -f "$d/pane_after_send" ]; then
                mv "$d/pane_after_send" "$d/pane"
            fi
        fi
        ;;
    kill-session)
        printf '%s\n' "${3:-}" >>"$d/killed"
        if [ -f "$d/session" ]; then
            grep -vxF -- "${3:-}" "$d/session" >"$d/session.tmp" 2>/dev/null || true
            mv "$d/session.tmp" "$d/session"
        fi
        ;;
    new-session)
        # Opt-in: only a test that reaches the send path creates the ready
        # file, so a launch in a pane that cannot take input still fails fast
        # (wait_ready would otherwise poll for the whole window).
        if [ -f "$d/ready" ]; then
            prev=''
            for arg in "$@"; do
                if [ "$prev" = -s ]; then printf '%s\n' "$arg" >>"$d/session"; fi
                prev=$arg
            done
        fi
        ;;
    list-sessions)
        cat "$d/session" 2>/dev/null || true
        ;;
    *)
        exit 0
        ;;
esac
FAKE
chmod +x "$TMP/bin/tmux"
export FREEBUFF_TMUX="$TMP/bin/tmux"
export FAKE_TMUX_DIR="$FAKE_DIR"

fake_session() {
    printf '%s\n' "$2" >"$FAKE_DIR/pane"
    printf 'fb-%s\n' "$1" >"$FAKE_DIR/session"
    printf '%s\n' "${3:-$(date +%s)}" >"$FAKE_DIR/activity"
    : >"$FAKE_DIR/killed"
    : >"$FAKE_DIR/sent"
}

fake_clear() {
    rm -f "$FAKE_DIR/session"
    : >"$FAKE_DIR/killed"
    : >"$FAKE_DIR/sent"
}

fake_add_session() {
    # fake_add_session NAME: add a live fb-* session next to the fixture one
    printf 'fb-%s\n' "$1" >>"$FAKE_DIR/session"
}

# Panes as captured from Freebuff 0.2.38.
IDLE_PANE='╭──────────────────╮
│  ▍Enter a coding task or / for commands
╰──────────────────╯
 DeepSeek V4.1 Flash • high · /tmp/x/proj · /model to change · Chat: New chat'
BUSY_PANE='thinking...                                      7s  ■ Esc
╭──────────────────╮
│  ▍Add to the current task (/ for commands)'
# A pane with no busy marker and no idle prompt: no rule can classify it, so
# it is `unknown` with evidence instead of the old working fallback.
NOMARKER_PANE='⎘ • 6s • △▽
╭──────────────────╮
│  ▍Add to the current task (/ for commands)'
REFUSED_PANE='Your concurrent-session limit across CLI and Desktop is reached.
Enter: take over  Esc: back to draft'
# The anti-automation refusal is a finished turn, not chrome: the sentence
# sits above the resting prompt, so a chrome-only check reads this as idle.
STRIKE_PANE='Freebuff did not send this message to the model. It breaks the usage policy (Scripted or automated use): it is the same message sent over and over, or automated account or site farming. It counts as strike 1 today. Strikes reset at midnight, when your daily hours refill.
╭──────────────────╮
│  ▍Enter a coding task or / for commands
╰──────────────────╯
 DeepSeek V4.1 Flash • high · /tmp/x/proj · /model to change · Chat: New chat'
# The account budget line is part of the same refusal vocabulary.
BUDGET_PANE='Your account budget for today is exhausted.
╭──────────────────╮
│  ▍Enter a coding task or / for commands
╰──────────────────╯
 DeepSeek V4.1 Flash • high · /tmp/x/proj · /model to change · Chat: New chat'
APPROVAL_PANE='Run command: git status
Allow once   Allow always   Deny'
# Captured from 0.2.38: the startup banner sits inside the 12-line window
# together with the resting prompt, so the prompt has to win.
BANNER_IDLE_PANE=' Can.t reach Freebuff.s servers. Retrying… Try another network.
╭──────────────────╮
│  ▍Enter a coding task or / for commands
╰──────────────────╯
 DeepSeek V4.1 Flash 10/17 • high · /tmp/x/proj · /model to change · Chat: New chat'
# Same banner with a turn in flight: no busy marker, mid-turn prompt.
BANNER_BUSY_PANE=' Can.t reach Freebuff.s servers. Retrying… Try another network.
⎘ • 6s • △▽
╭──────────────────╮
│  ▍Add to the current task (/ for commands)'
# Agent prose mentioning a permission must not outrank the resting prompt.
PROSE_AT_PROMPT_PANE='No permission was required for that deletion.
╭──────────────────╮
│  ▍Enter a coding task or / for commands
╰──────────────────╯
 DeepSeek V4.1 Flash • high · /tmp/x/proj · /model to change · Chat: New chat'

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

# gc: a done session is stopped and evidence appended
printf 'state=done\npr=none\n' >"$WT/.agent-result"
out=$(bash "$TOOL" --root "$REPO" gc --idle-hours 1)
check contains "$out" 'stop name=test-999 reason=done'
check contains "$out" 'cleanup=git worktree remove .worktrees/test-999'
check grep -qxF 'fb-test-999' "$FAKE_DIR/killed"
check test -d "$WT"
check contains "$(cat "$WT/.supervisor.log")" 'reason=done'
rm -f "$WT/.agent-result"

# gc: orphan session needs --all
printf 'fb-ghost\n' >"$FAKE_DIR/session"
printf 'Enter a coding task\n' >"$FAKE_DIR/pane"
printf '%s\n' "$(date +%s)" >"$FAKE_DIR/activity"
: >"$FAKE_DIR/killed"
out=$(bash "$TOOL" --root "$REPO" gc --idle-hours 1 --dry-run)
check contains "$out" 'skip name=ghost reason=orphan (use --all)'
check test ! -s "$FAKE_DIR/killed"

out=$(bash "$TOOL" --root "$REPO" gc --all --idle-hours 1 --dry-run)
check contains "$out" 'would-stop name=ghost reason=orphan'
check test ! -s "$FAKE_DIR/killed"

out=$(bash "$TOOL" --root "$REPO" gc --all --idle-hours 1)
check contains "$out" 'stop name=ghost reason=orphan'
check grep -qxF 'fb-ghost' "$FAKE_DIR/killed"
check test -f "$REPO/.worktrees/.orphans.log"
check contains "$(cat "$REPO/.worktrees/.orphans.log")" 'reason=orphan'

fake_clear

# ---- session inventory (#11) ----

fake_session test-999 "$IDLE_PANE"
printf 'state=blocked\n' >"$WT/.agent-result"
fake_add_session ghost
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
check contains "$out" 'sessions=2 running=2 worktrees=1 orphans=1'

# a watcher that was recorded but has gone is not reported as alive
printf 'autostop=pid:999999\n' >>"$WT/.supervisor.log"
out=$(bash "$TOOL" --root "$REPO" sessions --no-gh)
check test "$(printf '%s\n' "$out" | awk '$1 == "test-999" { print $4 }')" = dead

# list names the orphan, so it cannot be reaped without ever being seen
out=$(bash "$TOOL" --root "$REPO" list)
check contains "$out" 'orphans=ghost'

# even a root with no worktrees reports the orphan instead of only "no worktrees"
mkdir -p "$TMP/no-worktrees"
out=$(bash "$TOOL" --root "$TMP/no-worktrees" list)
check contains "$out" 'no worktrees'
check contains "$out" 'orphans=test-999 ghost'
rm -f "$WT/.agent-result"

# ---- machine-readable output (#17) ----

# zero sessions is an empty array, not an empty line
fake_clear
mkdir -p "$TMP/empty-json"
out=$(bash "$TOOL" --root "$TMP/empty-json" sessions --json --no-gh)
check test "$out" = '[]'
check json_ok "$out"

# two rows: a live session with a worktree, and an orphan with none
fake_session test-999 "$IDLE_PANE"
fake_add_session ghost
printf 'state=blocked\npr=https://example.test/pr/17\ncommit=def5678\ntests=sessions --json\n' \
    >"$WT/.agent-result"
out=$(bash "$TOOL" --root "$REPO" sessions --json --no-gh)
check json_ok "$out"
check contains "$out" '"name": "test-999"'
check contains "$out" '"name": "ghost"'
check test "$(printf '%s\n' "$out" | grep -c '^  {')" = 2
check contains "$out" '"worktree": "yes"'
check contains "$out" '"worktree": "missing"'
# the result file outranks the pane for test-999, the orphan is just idle
check contains "$out" '"state": "done"'
check contains "$out" '"state": "idle"'
check contains "$out" '"result": "blocked"'
# absent values are null, not the table's `-`
check test "$(printf '%s\n' "$out" | grep -c '"result": null')" = 1
check test "$(printf '%s\n' "$out" | grep -c '"branch": null')" = 1
check test "$(printf '%s\n' "$out" | grep -c '"watcher": null')" = 1
check contains "$out" '"watcher": "dead"'
# --no-gh leaves both PR fields null instead of the table's `-`
check test "$(printf '%s\n' "$out" | grep -c '"pr": null')" = 2

# status --json round-trips the result file
out=$(bash "$TOOL" --root "$REPO" status --json --no-gh test-999)
check json_ok "$out"
check contains "$out" '"state": "blocked"'
check contains "$out" '"result_state": "blocked"'
check contains "$out" '"result_pr": "https://example.test/pr/17"'
check contains "$out" '"result_commit": "def5678"'
check contains "$out" '"result_tests": "sessions --json"'
check contains "$out" '"running": true'
check contains "$out" '"input": "canonical"'
check contains "$out" '"session_state": "done"'
check contains "$out" '"dirty": false'
check contains "$out" '"pane": "'

# quotes, backslashes, tabs, CR and other control bytes are escaped, never raw
printf 'col1\tcol2\r\nquote " slash \\ esc \001 end\n' >"$FAKE_DIR/pane"
out=$(bash "$TOOL" --root "$REPO" status --json --no-gh test-999)
check json_ok "$out"
check contains "$out" '\t'
check contains "$out" '\r'
check contains "$out" '\\'
check contains "$out" '\"'
check contains "$out" '\u0001'
check test "$(printf '%s' "$out" | grep -c $'\t')" = 0

# a session that is gone is running=false with a null pane, not a missing key
fake_clear
out=$(bash "$TOOL" --root "$REPO" status --json --no-gh test-999)
check json_ok "$out"
check contains "$out" '"running": false'
check contains "$out" '"session_state": "missing"'
check contains "$out" '"pane": null'

fake_session test-999 "$IDLE_PANE"
rm -f "$WT/.agent-result"

# ---- static snapshot (#18) ----

# an empty root says so instead of emitting an empty table (and no live
# session can leak in from the shared fake tmux)
fake_clear
mkdir -p "$TMP/empty-gui"
bash "$TOOL" --root "$TMP/empty-gui" gui --snapshot "$TMP/empty.html" \
    --no-gh >/dev/null
check test -f "$TMP/empty.html"
check contains "$(cat "$TMP/empty.html")" 'no sessions'
check test "$(grep -c '<article' "$TMP/empty.html")" = 0

# two sessions and one orphan: one done, the others working, one no worktree
bash "$TOOL" --root "$REPO" start --issue 996 --name test-two \
    --branch test/two --title T --url U --no-start >/dev/null
printf 'state=blocked\npr=https://example.test/pr/18\ncommit=abc1234\ntests=ok <b>&"quoted"</b>\n' \
    >"$WT/.agent-result"
fake_session test-999 "$BUSY_PANE"
fake_add_session test-two
fake_add_session ghost
bash "$TOOL" --root "$REPO" gui --snapshot "$TMP/snap.html" --no-gh \
    >"$TMP/gui.out"
SNAP=$(cat "$TMP/snap.html")
check contains "$(cat "$TMP/gui.out")" "snapshot=$TMP/snap.html"
check test "$(printf '%s\n' "$SNAP" | grep -c '<article')" = 3
check contains "$SNAP" '<h2>test-999</h2>'
check contains "$SNAP" '<h2>test-two</h2>'
check contains "$SNAP" '<h2>ghost</h2>'
check contains "$SNAP" 'no worktree'
# the result file outranks the busy pane, so done versus working is visible
check contains "$SNAP" 'card state-done'
check contains "$SNAP" 'card state-working'
# arbitrary text is escaped, never markup
check contains "$SNAP" 'ok &lt;b&gt;&amp;&quot;quoted&quot;&lt;/b&gt;'
check test "$(printf '%s' "$SNAP" | grep -c '<b>')" = 0
check test "$(printf '%s' "$SNAP" | grep -c '<script')" = 0
# no server, no external assets, and a strict inline-style-only CSP
check contains "$SNAP" "default-src 'none'; style-src 'unsafe-inline'; img-src data:; connect-src 'self'"
# connect-src is same-origin only: no external fetch is permitted
check test "$(printf '%s' "$SNAP" | grep -c "connect-src 'self'")" = 1
check test "$(printf '%s' "$SNAP" | grep -cE '(href|src)="https?://')" = 0

# --watch rewrites the file and asks the browser to reload it
bash "$TOOL" --root "$REPO" gui --snapshot "$TMP/watch.html" --no-gh \
    --watch 1 >"$TMP/gui-watch.out" 2>&1 &
guipid=$!
sleep 1.2
check test -f "$TMP/watch.html"
check contains "$(cat "$TMP/watch.html")" 'http-equiv="refresh" content="1"'
check contains "$(cat "$TMP/gui-watch.out")" 'watch_seconds=1'
kill "$guipid" 2>/dev/null || true
wait "$guipid" 2>/dev/null || true

rm -f "$WT/.agent-result"
fake_clear

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

# ---- brief ledger: never the same text twice (#48) ----

# Reach the real send path: a stub freebuff, a fake stty that reports raw
# mode, and a fake tmux that registers the session it was asked to create.
cat >"$TMP/bin/stty" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' 'speed 38400 baud; line = 0; -icanon -echo'
FAKE
cat >"$TMP/bin/freebuff" <<'FAKE'
#!/usr/bin/env bash
exit 0
FAKE
chmod +x "$TMP/bin/stty" "$TMP/bin/freebuff"
PATH="$TMP/bin:$PATH"
export PATH
export FREEBUFF_BIN="$TMP/bin/freebuff"
: >"$FAKE_DIR/ready"
printf '%s\n' "$IDLE_PANE" >"$FAKE_DIR/pane"
fake_clear
: >"$FAKE_DIR/sent"

launch_brief() {
    # launch_brief NAME ISSUE [extra...]: one start that reaches the send
    bash "$TOOL" --root "$REPO" start --issue "$2" --name "$1" \
        --branch "test/$1" --title T --url U ${3+"${@:3}"}
}

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
rm -f "$FAKE_DIR/fast_sleep"
fake_clear

# ---- remaining checks ----

if bash "$TOOL" --root "$REPO" start --issue 999 --name test-999 \
    --branch test/999 --no-start >/dev/null 2>&1; then
    check false
else
    check true
fi

out=$(bash "$TOOL" --root "$REPO" stop test-999)
check contains "$out" 'stopped=no'

printf '# Custom brief\n\nDo the thing.\n' >"$TMP/custom.md"
bash "$TOOL" --root "$REPO" start --issue 998 --name test-custom \
    --branch test/custom --task-file "$TMP/custom.md" --no-start >/dev/null
check contains "$(cat "$REPO/.worktrees/test-custom/.task.md")" 'Do the thing.'

check contains "$(bash "$TOOL" --help 2>&1)" 'start'
check contains "$(bash "$TOOL" --help 2>&1)" 'gui --serve'

# ---- read-only server (#19) ----

# The server shells out to sessions/status, so the same fake tmux is enough:
# two inventory rows, one orphan, and arbitrary branch text to escape.
fake_session test-999 "$IDLE_PANE"
fake_add_session ghost
printf 'state=blocked\npr=https://example.test/pr/19\ncommit=abc1234\ntests=server\n' \
    >"$WT/.agent-result"
git -C "$WT" branch -m 'evil<&"branch'

if command -v python3 >/dev/null 2>&1 && command -v curl >/dev/null 2>&1; then
    : >"$TMP/gui.out"
    : >"$TMP/gui.err"
    bash "$TOOL" --root "$REPO" gui --serve --port 0 --token s3cret \
        >"$TMP/gui.out" 2>"$TMP/gui.err" &
    gui_pid=$!
    i=0
    while [ "$i" -lt 100 ]; do
        if grep -q '^listening=' "$TMP/gui.out" 2>/dev/null; then break; fi
        sleep 0.1
        i=$((i + 1))
    done
    base=$(sed -n 's/^listening=//p' "$TMP/gui.out" | head -n 1)
    check test -n "$base"

    # /api/sessions is sessions --json, verbatim: the same rows the CLI lists
    code=$(curl -sS --max-time 10 -o "$TMP/gui.body" -w '%{http_code}' \
        -H 'Authorization: Bearer s3cret' "$base/api/sessions" || true)
    check test "$code" = 200
    check json_ok "$(cat "$TMP/gui.body")"
    check contains "$(cat "$TMP/gui.body")" '"name": "test-999"'
    check contains "$(cat "$TMP/gui.body")" '"name": "ghost"'
    check contains "$(cat "$TMP/gui.body")" '"worktree": "yes"'
    check contains "$(cat "$TMP/gui.body")" '"worktree": "missing"'
    api_names=$(python3 -c 'import json,sys
print("\n".join(s["name"] for s in json.load(sys.stdin)))' \
        <"$TMP/gui.body")
    cli_names=$(bash "$TOOL" --root "$REPO" sessions --json |
        python3 -c 'import json,sys
print("\n".join(s["name"] for s in json.load(sys.stdin)))')
    check test "$api_names" = "$cli_names"

    # the dashboard is one page, escaped, with the orphan visibly worktree-less
    code=$(curl -sS --max-time 10 -o "$TMP/gui.body" -w '%{http_code}' \
        -H 'Authorization: Bearer s3cret' "$base/" || true)
    check test "$code" = 200
    check contains "$(cat "$TMP/gui.body")" 'freebuff agents'
    check contains "$(cat "$TMP/gui.body")" 'no worktree'
    check contains "$(cat "$TMP/gui.body")" 'test-999'
    check contains "$(cat "$TMP/gui.body")" 'ghost'
    check contains "$(cat "$TMP/gui.body")" 'evil&lt;&amp;&quot;branch'
    case "$(cat "$TMP/gui.body")" in
        *'evil<&"branch'*) check false ;;
        *) check true ;;
    esac

    # the pane tail, and 404 for a name that does not exist
    code=$(curl -sS --max-time 10 -o "$TMP/gui.body" -w '%{http_code}' \
        -H 'Authorization: Bearer s3cret' \
        "$base/api/session/test-999/pane" || true)
    check test "$code" = 200
    check json_ok "$(cat "$TMP/gui.body")"
    check contains "$(cat "$TMP/gui.body")" 'Enter a coding task'
    code=$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' \
        -H 'Authorization: Bearer s3cret' "$base/api/session/nope/pane" || true)
    check test "$code" = 404

    # bad auth is 401; a crafted name never reaches a path and is 400
    code=$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' \
        "$base/api/sessions" || true)
    check test "$code" = 401
    code=$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' \
        -H 'Authorization: Bearer wrong' "$base/api/sessions" || true)
    check test "$code" = 401
    code=$(curl -sS --max-time 10 --path-as-is -o /dev/null -w '%{http_code}' \
        -H 'Authorization: Bearer s3cret' \
        "$base/api/session/../etc/pane" || true)
    check test "$code" = 400
    code=$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' \
        -H 'Authorization: Bearer s3cret' \
        "$base/api/session/%2e%2e%2fetc/pane" || true)
    check test "$code" = 400

    # the token is accepted as a cookie too, and ?token= sets that cookie
    code=$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' \
        -H 'Cookie: fb_token=s3cret' "$base/api/sessions" || true)
    check test "$code" = 200
    curl -sS --max-time 10 -D "$TMP/gui.headers" -o /dev/null \
        "$base/?token=s3cret" || true
    check grep -qi '^set-cookie: fb_token=s3cret' "$TMP/gui.headers"
    check grep -qi 'httponly' "$TMP/gui.headers"

    # ---- actions (#22) ----
    # Each action is one CLI call, so the fake tmux is the observable: it
    # records kills and the literal send text, and the HTTP layer is checked
    # for its status, its body and the argv it produced.
    rm -f "$WT/.agent-result"

    # a graceful stop of an idle session kills fb-test-999 and records why
    rm -f "$WT/.supervisor.log"
    fake_session test-999 "$IDLE_PANE"
    code=$(curl -sS --max-time 30 -o "$TMP/gui.body" -w '%{http_code}' \
        -X POST -H 'Authorization: Bearer s3cret' \
        "$base/api/session/test-999/stop?graceful=1" || true)
    check test "$code" = 202
    check contains "$(cat "$TMP/gui.body")" 'stopped=fb-test-999'
    check grep -qxF 'fb-test-999' "$FAKE_DIR/killed"
    check contains "$(cat "$WT/.supervisor.log")" 'reason=graceful'
    check contains "$(cat "$WT/.supervisor.log")" 'pane_state=idle'

    # a turn that is still working is a 409 with the CLI's message and the
    # session survives: "stopped" and "still busy" must not both be 202
    rm -f "$FAKE_DIR/pane_after_escape"
    fake_session test-999 "$BUSY_PANE"
    code=$(curl -sS --max-time 60 -o "$TMP/gui.body" -w '%{http_code}' \
        -X POST -H 'Authorization: Bearer s3cret' \
        "$base/api/session/test-999/stop?graceful=1" || true)
    check test "$code" = 409
    check contains "$(cat "$TMP/gui.body")" 'still busy'
    check test ! -s "$FAKE_DIR/killed"
    check grep -qxF 'fb-test-999' "$FAKE_DIR/session"

    # send passes the text as one argv element: no shell, no word splitting
    fake_session test-999 "$IDLE_PANE"
    pwned="$TMP/pwned-$$"
    send_text="line one; \$(touch $pwned) && echo two"
    payload=$(printf '{"text": "%s"}' "$send_text")
    code=$(curl -sS --max-time 10 -o "$TMP/gui.body" -w '%{http_code}' \
        -X POST -H 'Authorization: Bearer s3cret' \
        -H 'Content-Type: application/json' -d "$payload" \
        "$base/api/session/test-999/send" || true)
    check test "$code" = 202
    check test -z "$(cat "$TMP/gui.body")"
    check grep -qF -- "-l"$'\t'"$send_text"$'\t' "$FAKE_DIR/sent"
    check test ! -e "$pwned"

    # the text is body-only: a query string cannot smuggle one in
    code=$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' \
        -X POST -H 'Authorization: Bearer s3cret' \
        "$base/api/session/test-999/send?text=fromurl" || true)
    check test "$code" = 400
    code=$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' \
        -X POST -H 'Authorization: Bearer s3cret' \
        -H 'Content-Type: application/json' -d '{"text": ""}' \
        "$base/api/session/test-999/send" || true)
    check test "$code" = 400

    # every POST needs the token, even on loopback, and a refusal changes nothing
    : >"$FAKE_DIR/killed"
    code=$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' -X POST \
        "$base/api/session/test-999/stop?graceful=1" || true)
    check test "$code" = 401
    code=$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' -X POST \
        -H 'Authorization: Bearer wrong' \
        "$base/api/session/test-999/stop?graceful=1" || true)
    check test "$code" = 401
    check test ! -s "$FAKE_DIR/killed"
    check grep -qxF 'fb-test-999' "$FAKE_DIR/session"

    # unknown name is 404; a crafted name is 400 before any path or process
    code=$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' -X POST \
        -H 'Authorization: Bearer s3cret' "$base/api/session/nope/stop" || true)
    check test "$code" = 404
    code=$(curl -sS --max-time 10 --path-as-is -o /dev/null -w '%{http_code}' \
        -X POST -H 'Authorization: Bearer s3cret' \
        "$base/api/session/../etc/stop" || true)
    check test "$code" = 400
    code=$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' -X POST \
        -H 'Authorization: Bearer s3cret' \
        "$base/api/session/%2e%2e%2fetc/stop" || true)
    check test "$code" = 400

    # gc: dry-run reports what it would stop and changes nothing
    printf 'state=done\npr=none\n' >"$WT/.agent-result"
    fake_session test-999 "$IDLE_PANE"
    code=$(curl -sS --max-time 30 -o "$TMP/gui.body" -w '%{http_code}' \
        -X POST -H 'Authorization: Bearer s3cret' "$base/api/gc?dry=1" || true)
    check test "$code" = 202
    check contains "$(cat "$TMP/gui.body")" 'would-stop name=test-999 reason=done'
    check test ! -s "$FAKE_DIR/killed"

    # and the plain call performs it, with the CLI's own report
    code=$(curl -sS --max-time 30 -o "$TMP/gui.body" -w '%{http_code}' \
        -X POST -H 'Authorization: Bearer s3cret' "$base/api/gc" || true)
    check test "$code" = 202
    check contains "$(cat "$TMP/gui.body")" 'stop name=test-999 reason=done'
    check grep -qxF 'fb-test-999' "$FAKE_DIR/killed"
    rm -f "$WT/.agent-result"

    # --read-only answers every POST with 403 and leaves GET alone
    : >"$TMP/gui-ro.out"
    bash "$TOOL" --root "$REPO" gui --serve --port 0 --token s3cret \
        --read-only >"$TMP/gui-ro.out" 2>"$TMP/gui-ro.err" &
    ro_pid=$!
    i=0
    while [ "$i" -lt 100 ]; do
        if grep -q '^listening=' "$TMP/gui-ro.out" 2>/dev/null; then break; fi
        sleep 0.1
        i=$((i + 1))
    done
    ro_base=$(sed -n 's/^listening=//p' "$TMP/gui-ro.out" | head -n 1)
    check test -n "$ro_base"
    code=$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' -X POST \
        -H 'Authorization: Bearer s3cret' "$ro_base/api/sessions" || true)
    check test "$code" = 403
    code=$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' -X POST \
        -H 'Authorization: Bearer s3cret' \
        "$ro_base/api/session/test-999/stop" || true)
    check test "$code" = 403
    code=$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' -X POST \
        -H 'Authorization: Bearer s3cret' "$ro_base/api/gc?dry=1" || true)
    check test "$code" = 403
    code=$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' \
        -H 'Authorization: Bearer s3cret' "$ro_base/api/sessions" || true)
    check test "$code" = 200

    # a generated token is printed once on startup and works
    : >"$TMP/gui-gen.out"
    : >"$TMP/gui-gen.err"
    bash "$TOOL" --root "$REPO" gui --serve --port 0 \
        >"$TMP/gui-gen.out" 2>"$TMP/gui-gen.err" &
    gen_pid=$!
    i=0
    while [ "$i" -lt 100 ]; do
        if grep -q '^listening=' "$TMP/gui-gen.out" 2>/dev/null; then break; fi
        sleep 0.1
        i=$((i + 1))
    done
    gen_base=$(sed -n 's/^listening=//p' "$TMP/gui-gen.out" | head -n 1)
    gen_token=$(sed -n 's/^token=//p' "$TMP/gui-gen.err" | head -n 1)
    check test -n "$gen_base"
    check test -n "$gen_token"
    check test "$(grep -c '^token=' "$TMP/gui-gen.err" || true)" = 1
    check test "$(grep -c '^token=' "$TMP/gui-gen.out" || true)" = 0
    code=$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' \
        -H "Authorization: Bearer $gen_token" "$gen_base/api/sessions" || true)
    check test "$code" = 200

    kill "$gui_pid" "$ro_pid" "$gen_pid" 2>/dev/null || true
    wait "$gui_pid" 2>/dev/null || true
    wait "$ro_pid" 2>/dev/null || true
    wait "$gen_pid" 2>/dev/null || true

    # off-loopback without an explicit token is refused before anything binds
    gui_port=$((20000 + $$ % 20000))
    if bash "$TOOL" --root "$REPO" gui --serve --host 0.0.0.0 \
        --port "$gui_port" >"$TMP/gui.refuse" 2>&1; then refused=0; else refused=$?; fi
    check test "$refused" -ne 0
    check contains "$(cat "$TMP/gui.refuse")" 'refusing to bind'
    if curl -sS --max-time 2 "http://127.0.0.1:$gui_port/api/sessions" \
        >/dev/null 2>&1; then still_listening=yes; else still_listening=no; fi
    check test "$still_listening" = no

    # without python3 the command explains itself and the CLI is untouched
    nopy="$TMP/nopy"
    bash_bin=$(command -v bash)
    mkdir -p "$nopy"
    ln -sf "$(command -v git)" "$nopy/git"
    if PATH="$nopy" "$bash_bin" "$TOOL" --root "$REPO" gui --serve \
        >"$TMP/gui.nopy" 2>&1; then nopy_rc=0; else nopy_rc=$?; fi
    check test "$nopy_rc" -ne 0
    check contains "$(cat "$TMP/gui.nopy")" 'needs python3'

    # ---- live terminal through ttyd (#20) ----
    # A fake ttyd records its argv and holds the port open, so the read-only
    # posture, the credentials, the target and the loopback bind are all
    # checkable without a real ttyd, a browser or a Freebuff session.
    TTYD_DIR="$TMP/ttyd"
    mkdir -p "$TTYD_DIR"
    cat >"$TMP/bin/ttyd" <<'FAKE_TTYD'
#!/usr/bin/env bash
# argv on separate lines, then hold the port so the server's readiness probe
# succeeds and the HTTP redirect can be observed.
d=${FAKE_TTYD_DIR:?}
port=''
for arg in "$@"; do
    printf '%s\n' "$arg" >>"$d/ttyd_argv"
done
while [ $# -gt 0 ]; do
    case "$1" in
        -p) port=$2; shift 2 ;;
        *) shift ;;
    esac
done
printf '%s\n' "$$" >"$d/ttyd_pid"
exec python3 - "$port" <<'HOLD'
import socket, sys, time
sock = socket.socket()
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
sock.bind(("127.0.0.1", int(sys.argv[1])))
sock.listen(8)
time.sleep(120)
HOLD
FAKE_TTYD
    chmod +x "$TMP/bin/ttyd"
    export FREEBUFF_TTYD="$TMP/bin/ttyd"
    export FAKE_TTYD_DIR="$TTYD_DIR"
    : >"$TTYD_DIR/ttyd_argv"
    : >"$TTYD_DIR/ttyd_pid"
    fake_session test-999 "$IDLE_PANE"

    bash "$TOOL" --root "$REPO" gui --serve --port 0 --token s3cret --ttyd \
        >"$TMP/ttyd.out" 2>"$TMP/ttyd.err" &
    ttyd_gui=$!
    i=0
    while [ "$i" -lt 100 ]; do
        if grep -q '^listening=' "$TMP/ttyd.out" 2>/dev/null; then break; fi
        sleep 0.1
        i=$((i + 1))
    done
    ttyd_base=$(sed -n 's/^listening=//p' "$TMP/ttyd.out" | head -n 1)
    check test -n "$ttyd_base"
    check contains "$(cat "$TMP/ttyd.out")" 'ttyd=yes'

    # the served dashboard carries one terminal link per session
    code=$(curl -sS --max-time 10 -o "$TMP/ttyd.body" -w '%{http_code}' \
        -H 'Authorization: Bearer s3cret' "$ttyd_base/" || true)
    check test "$code" = 200
    check contains "$(cat "$TMP/ttyd.body")" 'href="/tty/test-999"'

    # following it starts ttyd: loopback, basic auth, the tmux target, and
    # read-only by default (ttyd is read-only unless -W is given)
    code=$(curl -sS --max-time 10 -D "$TMP/ttyd.headers" -o /dev/null \
        -w '%{http_code}' -H 'Authorization: Bearer s3cret' \
        "$ttyd_base/tty/test-999" || true)
    check test "$code" = 302
    location=$(sed -n 's/^[Ll]ocation: //p' "$TMP/ttyd.headers" |
        tr -d '\r' | head -n 1)
    check contains "$location" 'http://127.0.0.1:'
    check grep -qxF -- '-i' "$TTYD_DIR/ttyd_argv"
    check grep -qxF -- '127.0.0.1' "$TTYD_DIR/ttyd_argv"
    check grep -qxF -- '-c' "$TTYD_DIR/ttyd_argv"
    check grep -qxF -- 'fb:s3cret' "$TTYD_DIR/ttyd_argv"
    check grep -qxF -- 'attach' "$TTYD_DIR/ttyd_argv"
    check grep -qxF -- '-t' "$TTYD_DIR/ttyd_argv"
    check grep -qxF -- 'fb-test-999' "$TTYD_DIR/ttyd_argv"
    check test "$(grep -cxF -- '-W' "$TTYD_DIR/ttyd_argv" || true)" = 0
    check test "$(grep -cxF -- 'fb:s3cret' "$TTYD_DIR/ttyd_argv" || true)" = 1

    # a second click reuses the running viewer instead of starting another
    spawns=$(wc -l <"$TTYD_DIR/ttyd_argv")
    code=$(curl -sS --max-time 10 -D "$TMP/ttyd.headers2" -o /dev/null \
        -w '%{http_code}' -H 'Authorization: Bearer s3cret' \
        "$ttyd_base/tty/test-999" || true)
    check test "$code" = 302
    check test "$(wc -l <"$TTYD_DIR/ttyd_argv")" = "$spawns"
    check test "$(sed -n 's/^[Ll]ocation: //p' "$TMP/ttyd.headers2" |
        tr -d '\r' | head -n 1)" = "$location"

    # a session that is not running is refused instead of spawning ttyd
    fake_clear
    code=$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' \
        -H 'Authorization: Bearer s3cret' "$ttyd_base/tty/test-999" || true)
    check test "$code" = 409
    fake_session test-999 "$IDLE_PANE"

    # the name goes through the phase 3 validation before any process
    code=$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' \
        -H 'Authorization: Bearer s3cret' "$ttyd_base/tty/nope" || true)
    check test "$code" = 404
    code=$(curl -sS --max-time 10 --path-as-is -o /dev/null -w '%{http_code}' \
        -H 'Authorization: Bearer s3cret' \
        "$ttyd_base/tty/..%2fetc" || true)
    check test "$code" = 400

    # stopping the server reaps the viewer it started
    viewer_pid=$(cat "$TTYD_DIR/ttyd_pid")
    check test -n "$viewer_pid"
    kill "$ttyd_gui" 2>/dev/null || true
    wait "$ttyd_gui" 2>/dev/null || true
    reaped=no
    for i in 1 2 3 4 5 6 7 8 9 10; do
        if kill -0 "$viewer_pid" 2>/dev/null; then sleep 0.2; else reaped=yes; break; fi
    done
    check test "$reaped" = yes

    # --interactive drops ttyd's read-only default and adds -W
    : >"$TTYD_DIR/ttyd_argv"
    fake_session test-999 "$IDLE_PANE"
    bash "$TOOL" --root "$REPO" gui --serve --port 0 --token s3cret --ttyd \
        --interactive >"$TMP/ttyd-i.out" 2>&1 &
    ttyd_i=$!
    i=0
    while [ "$i" -lt 100 ]; do
        if grep -q '^listening=' "$TMP/ttyd-i.out" 2>/dev/null; then break; fi
        sleep 0.1
        i=$((i + 1))
    done
    i_base=$(sed -n 's/^listening=//p' "$TMP/ttyd-i.out" | head -n 1)
    check test -n "$i_base"
    check contains "$(cat "$TMP/ttyd-i.out")" 'interactive=yes'
    code=$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' \
        -H 'Authorization: Bearer s3cret' "$i_base/tty/test-999" || true)
    check test "$code" = 302
    check grep -qxF -- '-W' "$TTYD_DIR/ttyd_argv"
    kill "$ttyd_i" 2>/dev/null || true
    wait "$ttyd_i" 2>/dev/null || true

    # --read-only plus --interactive is refused, not silently downgraded
    if FREEBUFF_TTYD="$TMP/bin/ttyd" bash "$TOOL" --root "$REPO" gui \
        --serve --port 0 --token s3cret --read-only --ttyd --interactive \
        >"$TMP/ttyd-ro.out" 2>&1; then ro_int=0; else ro_int=$?; fi
    check test "$ro_int" -ne 0
    check contains "$(cat "$TMP/ttyd-ro.out")" 'read-only'

    # --interactive alone is a usage error
    if bash "$TOOL" --root "$REPO" gui --serve --port 0 --interactive \
        >"$TMP/ttyd-need.out" 2>&1; then need_rc=0; else need_rc=$?; fi
    check test "$need_rc" -ne 0
    check contains "$(cat "$TMP/ttyd-need.out")" 'needs --ttyd'

    # no ttyd: the server still runs, the dashboard has no links and says why
    FREEBUFF_TTYD="$TMP/not-a-ttyd" bash "$TOOL" --root "$REPO" gui \
        --serve --port 0 --token s3cret --ttyd \
        >"$TMP/ttyd-miss.out" 2>"$TMP/ttyd-miss.err" &
    ttyd_miss=$!
    i=0
    while [ "$i" -lt 100 ]; do
        if grep -q '^listening=' "$TMP/ttyd-miss.out" 2>/dev/null; then break; fi
        sleep 0.1
        i=$((i + 1))
    done
    m_base=$(sed -n 's/^listening=//p' "$TMP/ttyd-miss.out" | head -n 1)
    check test -n "$m_base"
    check contains "$(cat "$TMP/ttyd-miss.out")" 'ttyd=missing'
    code=$(curl -sS --max-time 10 -o "$TMP/ttyd-miss.body" -w '%{http_code}' \
        -H 'Authorization: Bearer s3cret' "$m_base/" || true)
    check test "$code" = 200
    check contains "$(cat "$TMP/ttyd-miss.body")" 'ttyd not found'
    check test "$(grep -c 'href="/tty/' "$TMP/ttyd-miss.body" || true)" = 0
    code=$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' \
        -H 'Authorization: Bearer s3cret' "$m_base/tty/test-999" || true)
    check test "$code" = 503
    kill "$ttyd_miss" 2>/dev/null || true
    wait "$ttyd_miss" 2>/dev/null || true

    unset FREEBUFF_TTYD FAKE_TTYD_DIR
    fake_clear
else
    printf 'skip gui server checks: python3 or curl missing\n' >&2
fi

git -C "$WT" branch -m 'test/999'
rm -f "$WT/.agent-result"

git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1 || true
git -C "$REPO" worktree remove --force "$REPO/.worktrees/test-custom" >/dev/null 2>&1 || true
git -C "$REPO" worktree remove --force "$REPO/.worktrees/test-dead" >/dev/null 2>&1 || true
for brief in a b c; do
    git -C "$REPO" worktree remove --force "$REPO/.worktrees/test-brief-$brief" \
        >/dev/null 2>&1 || true
done
for refused in overlay turn next; do
    git -C "$REPO" worktree remove --force "$REPO/.worktrees/test-refuse-$refused" \
        >/dev/null 2>&1 || true
done
for ready in slow hung warm; do
    git -C "$REPO" worktree remove --force "$REPO/.worktrees/test-$ready" \
        >/dev/null 2>&1 || true
done
git -C "$REPO" branch -D test/999 test/custom test/dead \
    test/test-brief-a test/test-brief-b test/test-brief-c \
    test/test-refuse-overlay test/test-refuse-turn test/test-refuse-next \
    test/slow test/hung test/warm \
    >/dev/null 2>&1 || true

if [ "$failed" -ne 0 ]; then
    printf '%d/%d checks failed\n' "$failed" "$total" >&2
    exit 1
fi
printf 'ok %d checks\n' "$total"
