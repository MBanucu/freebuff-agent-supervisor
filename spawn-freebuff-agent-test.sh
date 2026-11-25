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
cat >"$TMP/bin/tmux" <<'FAKE'
#!/usr/bin/env bash
d=${FAKE_TMUX_DIR:?}
case "${1:-}" in
    has-session)
        [ "$(cat "$d/session" 2>/dev/null || true)" = "${3:-}" ]
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
    kill-session)
        printf '%s\n' "${3:-}" >>"$d/killed"
        rm -f "$d/session"
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

IDLE_PANE='Welcome to Freebuff

Enter a coding task'
BUSY_PANE='Working for 12s
esc to interrupt'
REFUSED_PANE='Your concurrent-session limit across CLI and Desktop is reached.
Enter: take over  Esc: back to draft'
APPROVAL_PANE='Run command: git status
Allow once   Allow always   Deny'

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

# watch: an approval prompt is not idle
fake_session test-999 "$APPROVAL_PANE"
if bash "$TOOL" --root "$REPO" watch test-999 --timeout 1 --poll 1 \
    >"$TMP/watch.out" 2>&1; then rc=0; else rc=$?; fi
check test "$rc" -eq 1
check contains "$(cat "$TMP/watch.out")" 'state=working'

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

git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1 || true
git -C "$REPO" worktree remove --force "$REPO/.worktrees/test-custom" >/dev/null 2>&1 || true
git -C "$REPO" branch -D test/999 test/custom >/dev/null 2>&1 || true

if [ "$failed" -ne 0 ]; then
    printf '%d/%d checks failed\n' "$failed" "$total" >&2
    exit 1
fi
printf 'ok %d checks\n' "$total"
