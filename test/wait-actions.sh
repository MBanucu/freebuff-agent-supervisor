#!/usr/bin/env bash
# Area: the read-only server (#19), its POST actions (#22) and the live
# terminal through ttyd (#20).

# shellcheck shell=bash
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

[ -d "$WT" ] || bash "$TOOL" --root "$REPO" start --issue 999 --name test-999 \
    --branch test/999 --title 'Test issue' \
    --url 'https://example.test/issues/999' --no-start >/dev/null
rm -f "$WT/.agent-result" "$WT/.refusal"

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

git -C "$WT" branch -m 'test/999' 2>/dev/null || true
rm -f "$WT/.agent-result"
