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
            *pane_tty*) printf '%s\n' "$d/tty" ;;
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
        fi
        ;;
    kill-session)
        printf '%s\n' "${3:-}" >>"$d/killed"
        if [ -f "$d/session" ]; then
            grep -vxF -- "${3:-}" "$d/session" >"$d/session.tmp" 2>/dev/null || true
            mv "$d/session.tmp" "$d/session"
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
}

fake_clear() {
    rm -f "$FAKE_DIR/session"
    : >"$FAKE_DIR/killed"
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
# A pane with no busy marker and no idle prompt: the fallback must call it working.
NOMARKER_PANE='⎘ • 6s • △▽
╭──────────────────╮
│  ▍Add to the current task (/ for commands)'
REFUSED_PANE='Your concurrent-session limit across CLI and Desktop is reached.
Enter: take over  Esc: back to draft'
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

# a pane with neither marker still counts as working
fake_session test-999 "$NOMARKER_PANE"
out=$(bash "$TOOL" --root "$REPO" status --no-gh test-999)
check contains "$out" 'session_state=working'

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
    check contains "$(cat "$TMP/gui.body")" 'Freebuff sessions'
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
else
    printf 'skip gui server checks: python3 or curl missing\n' >&2
fi

git -C "$WT" branch -m 'test/999'
rm -f "$WT/.agent-result"

git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1 || true
git -C "$REPO" worktree remove --force "$REPO/.worktrees/test-custom" >/dev/null 2>&1 || true
git -C "$REPO" worktree remove --force "$REPO/.worktrees/test-dead" >/dev/null 2>&1 || true
git -C "$REPO" branch -D test/999 test/custom test/dead >/dev/null 2>&1 || true

if [ "$failed" -ne 0 ]; then
    printf '%d/%d checks failed\n' "$failed" "$total" >&2
    exit 1
fi
printf 'ok %d checks\n' "$total"
