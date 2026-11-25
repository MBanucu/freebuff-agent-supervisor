#!/usr/bin/env bash
# Curl-based checks for gui/server.py. A temporary git repo and a fake tmux
# stand in for a supervisor root and its sessions, so nothing here needs
# Freebuff, an account slot, gh or the network.
#
# The server is started on --port 0 and reports its listening URL; readiness
# is a poll of that port, never a fixed sleep. Every server started here is
# killed by the EXIT trap and each one is checked closed afterwards, so a
# failing check cannot leave a listener behind.
set -euo pipefail

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd) || exit 1
TOOL="$ROOT/spawn-freebuff-agent"
TOKEN=s3cret

# The CLI suite keeps working without python3; only the server needs it, so
# this harness skips instead of failing when the pieces are missing.
if ! command -v python3 >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
    printf 'skip gui server checks: python3 or curl missing\n' >&2
    exit 0
fi

TMP=$(mktemp -d) || exit 1
REPO="$TMP/repo"
FAKE_DIR="$TMP/fake"
servers=()
cleanup() {
    local pid
    for pid in ${servers[@]+"${servers[@]}"}; do
        kill "$pid" 2>/dev/null || true
    done
    for pid in ${servers[@]+"${servers[@]}"}; do
        wait "$pid" 2>/dev/null || true
    done
    rm -rf "$TMP"
}
trap cleanup EXIT

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
    printf '%s' "${1-}" | python3 -m json.tool >/dev/null 2>&1
}

# One inventory row per worktree session and one orphan, compared field by
# field with what the CLI prints. idle_seconds is skipped because the two
# calls land seconds apart by design, not because the shape differs.
same_inventory() {
    python3 - "$1" "$2" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    api = json.load(handle)
with open(sys.argv[2], encoding="utf-8") as handle:
    cli = json.load(handle)
assert isinstance(api, list), "api is not an array"
assert len(api) == len(cli), (len(api), len(cli))
for served, printed in zip(api, cli):
    assert list(served) == list(printed), (list(served), list(printed))
    for key in served:
        if key == "idle_seconds":
            continue
        assert served[key] == printed[key], (key, served[key], printed[key])
PY
}

# A temp repo, one real worktree, and one orphan session with no worktree.
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email test@example.invalid
git -C "$REPO" config user.name Test
git -C "$REPO" config commit.gpgsign false
printf 'hello\n' >"$REPO/README.md"
git -C "$REPO" add README.md
git -C "$REPO" commit -qm init
git -C "$REPO" branch -M main

bash "$TOOL" --root "$REPO" start --issue 999 --name test-999 \
    --branch test/999 --title 'Test issue' \
    --url 'https://example.test/issues/999' --no-start >/dev/null
WT="$REPO/.worktrees/test-999"

# Fake tmux: fixture panes, recorded kills, and an activity file for idle.
mkdir -p "$FAKE_DIR" "$TMP/bin"
: >"$FAKE_DIR/tty"
: >"$FAKE_DIR/killed"
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
            *pane_tty*) printf '%s\n' "$d/tty" ;;
            *session_activity*) cat "$d/activity" 2>/dev/null || printf '0\n' ;;
            *) printf '0\n' ;;
        esac
        ;;
    send-keys)
        printf '%s\n' "${3:-}" >>"$d/sent"
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

# Panes as captured from Freebuff 0.2.38.
IDLE_PANE='╭──────────────────╮
│  ▍Enter a coding task or / for commands
╰──────────────────╯
 DeepSeek V4.1 Flash • high · /tmp/x/proj · /model to change · Chat: New chat'

fake_session() {
    # fake_session NAME PANE [ACTIVITY]
    printf '%s\n' "$2" >"$FAKE_DIR/pane"
    printf 'fb-%s\n' "$1" >"$FAKE_DIR/session"
    printf '%s\n' "${3:-$(date +%s)}" >"$FAKE_DIR/activity"
    : >"$FAKE_DIR/killed"
    : >"$FAKE_DIR/sent"
}

fake_add_session() {
    printf 'fb-%s\n' "$1" >>"$FAKE_DIR/session"
}

SERVER_PID=''
SERVER_BASE=''

start_server() {
    # start_server TAG [extra gui args]
    local tag=$1
    shift
    local out="$TMP/$tag.out"
    local err="$TMP/$tag.err"
    : >"$out"
    : >"$err"
    bash "$TOOL" --root "$REPO" gui --serve --port 0 --token "$TOKEN" "$@" \
        >"$out" 2>"$err" &
    local pid=$!
    servers+=("$pid")
    SERVER_PID=$pid
    SERVER_BASE=''
    local i base code
    for ((i = 0; i < 300; i++)); do
        base=$(sed -n 's/^listening=//p' "$out" 2>/dev/null | head -n 1)
        [ -n "$base" ] && break
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.05
    done
    if [ -z "$base" ]; then
        printf 'gui server did not report a listening URL\n' >&2
        cat "$err" >&2 || true
        return 1
    fi
    # Poll the port instead of sleeping: the server prints its URL before it
    # serves, so only a real request proves it is ready. 401 is that proof.
    for ((i = 0; i < 300; i++)); do
        code=$(curl -sS --max-time 1 -o /dev/null -w '%{http_code}' \
            "$base/api/sessions" 2>/dev/null || true)
        [ "$code" = 401 ] && break
        sleep 0.05
    done
    SERVER_BASE=$base
}

stop_server() {
    # stop_server PID BASE: stop it, then prove the port is closed.
    local pid=$1
    local base=$2
    local i
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    for ((i = 0; i < 100; i++)); do
        if ! curl -sS --max-time 1 -o /dev/null "$base/api/sessions" \
            2>/dev/null; then
            return 0
        fi
        sleep 0.05
    done
    return 1
}

# ---- a live session and an orphan, served with a token ----

fake_session test-999 "$IDLE_PANE" "$(($(date +%s) - 30))"
fake_add_session ghost

start_server main || true
base=$SERVER_BASE
check test -n "$SERVER_PID"
check test -n "$base"
check test "$(sed -n 's/^read_only=//p' "$TMP/main.out")" = no

# /api/sessions is `sessions --json` verbatim: same rows, same keys, orphan
# included, so a GUI cannot invent a row the CLI does not list.
code=$(curl -sS --max-time 10 -o "$TMP/api.json" -w '%{http_code}' \
    -H "Authorization: Bearer $TOKEN" "$base/api/sessions" || true)
check test "$code" = 200
check json_ok "$(cat "$TMP/api.json")"
check contains "$(cat "$TMP/api.json")" '"name": "test-999"'
check contains "$(cat "$TMP/api.json")" '"name": "ghost"'
check contains "$(cat "$TMP/api.json")" '"worktree": "yes"'
check contains "$(cat "$TMP/api.json")" '"worktree": "missing"'
bash "$TOOL" --root "$REPO" sessions --json >"$TMP/cli.json"
check same_inventory "$TMP/api.json" "$TMP/cli.json"

# The pane preview is status --json: a tail, not a screenshot.
code=$(curl -sS --max-time 10 -o "$TMP/pane.json" -w '%{http_code}' \
    -H "Authorization: Bearer $TOKEN" \
    "$base/api/session/test-999/pane" || true)
check test "$code" = 200
check json_ok "$(cat "$TMP/pane.json")"
check contains "$(cat "$TMP/pane.json")" '"pane":'
check contains "$(cat "$TMP/pane.json")" 'Enter a coding task'

# 401 without a token, and with the wrong one.
code=$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' \
    "$base/api/sessions" || true)
check test "$code" = 401
code=$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' \
    -H 'Authorization: Bearer wrong' "$base/api/sessions" || true)
check test "$code" = 401

# 404 for a name the inventory does not know.
code=$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer $TOKEN" \
    "$base/api/session/nope/pane" || true)
check test "$code" = 404

# 400 for a crafted name, before it can reach a path or a subprocess.
code=$(curl -sS --max-time 10 --path-as-is -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer $TOKEN" \
    "$base/api/session/../etc/pane" || true)
check test "$code" = 400
code=$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer $TOKEN" \
    "$base/api/session/%2e%2e%2fetc/pane" || true)
check test "$code" = 400
code=$(curl -sS --max-time 10 --path-as-is -o /dev/null -w '%{http_code}' \
    -X POST -H "Authorization: Bearer $TOKEN" \
    "$base/api/session/../etc/stop" || true)
check test "$code" = 400

# A graceful stop of an idle session kills the fake fb-* and records why.
rm -f "$WT/.supervisor.log"
fake_session test-999 "$IDLE_PANE"
code=$(curl -sS --max-time 30 -o "$TMP/stop.out" -w '%{http_code}' \
    -X POST -H "Authorization: Bearer $TOKEN" \
    "$base/api/session/test-999/stop?graceful=1" || true)
check test "$code" = 202
check contains "$(cat "$TMP/stop.out")" 'stopped=fb-test-999'
check grep -qxF 'fb-test-999' "$FAKE_DIR/killed"
check test ! -s "$FAKE_DIR/session"
check contains "$(cat "$WT/.supervisor.log")" 'reason=graceful'
check contains "$(cat "$WT/.supervisor.log")" 'pane_state=idle'

check stop_server "$SERVER_PID" "$base"

# ---- --read-only answers POST with 403 and leaves GET alone ----

start_server ro --read-only || true
ro_base=$SERVER_BASE
check test -n "$SERVER_PID"
check test -n "$ro_base"
check test "$(sed -n 's/^read_only=//p' "$TMP/ro.out")" = yes
code=$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer $TOKEN" "$ro_base/api/sessions" || true)
check test "$code" = 200
code=$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' -X POST \
    -H "Authorization: Bearer $TOKEN" \
    "$ro_base/api/session/test-999/stop" || true)
check test "$code" = 403
code=$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' -X POST \
    -H "Authorization: Bearer $TOKEN" "$ro_base/api/gc?dry=1" || true)
check test "$code" = 403
# auth still comes first: no token is 401 even in read-only mode
code=$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' -X POST \
    "$ro_base/api/session/test-999/stop" || true)
check test "$code" = 401

check stop_server "$SERVER_PID" "$ro_base"

if [ "$failed" -ne 0 ]; then
    printf '%d/%d gui checks failed\n' "$failed" "$total" >&2
    exit 1
fi
printf 'ok %d gui checks\n' "$total"
