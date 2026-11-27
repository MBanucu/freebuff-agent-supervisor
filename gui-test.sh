#!/usr/bin/env bash
# Curl-based checks for gui/server.py. test/lib.sh owns the temp repo, the
# fake tmux and the fixtures, so only the server-specific harness lives here.
# Nothing needs Freebuff, an account slot, gh or the network.
#
# The server is started on --port 0 and reports its listening URL; readiness
# is a poll of that port, never a fixed sleep. Every server started here is
# killed by the cleanup hook and each one is checked closed afterwards, so a
# failing check cannot leave a listener behind.
set -euo pipefail

# The CLI suite keeps working without python3; only the server needs it, so
# this harness skips instead of failing when the pieces are missing.
if ! command -v python3 >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
    printf 'skip gui server checks: python3 or curl missing\n' >&2
    exit 0
fi

# The CLI suite keeps working without the shared harness, but the server
# needs the temp repo and fixtures that test/lib.sh provides.
. "$(dirname -- "$0")/test/lib.sh"

TOKEN=s3cret

servers=()
cleanup_servers() {
    local pid
    for pid in ${servers[@]+"${servers[@]}"}; do
        kill "$pid" 2>/dev/null || true
    done
    for pid in ${servers[@]+"${servers[@]}"}; do
        wait "$pid" 2>/dev/null || true
    done
}
TEST_CLEANUP_HOOK=cleanup_servers

# The header set every response must carry, errors and redirects included.
# Kept as one string so the check is the wire's exact value, not a guess.
CSP="default-src 'none'; style-src 'unsafe-inline'; img-src data:; connect-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'"

header_is() {
    # header_is FILE NAME VALUE
    awk -v name="${2,,}" -v want="${3,,}" '
        { sub(/\r$/, ""); i = index($0, ":")
          if (i && tolower(substr($0, 1, i - 1)) == name) {
              v = tolower(substr($0, i + 1)); sub(/^ /, "", v)
              if (v == want) found = 1 } }
        END { exit found ? 0 : 1 }' "$1"
}

check_security_headers() {
    # check_security_headers FILE: the headers a meta tag cannot express
    local file=$1
    check header_is "$file" Content-Security-Policy "$CSP"
    check header_is "$file" X-Content-Type-Options nosniff
    check header_is "$file" X-Frame-Options DENY
    check header_is "$file" Referrer-Policy no-referrer
}

json_ok() {
    printf '%s' "${1-}" | python3 -m json.tool >/dev/null 2>&1
}

same_stylesheet() {
    # same_stylesheet PAGE DASHBOARD: the action page's inline CSS is the
    # dashboard's own gui/page.css, compared after trimming the <style> tags,
    # and the heading it renders is still there. One stylesheet, one place to
    # change a colour; only the markup differs.
    python3 - "$1" "$2" <<'PY'
import re
import sys


def style(path):
    with open(path, encoding="utf-8") as handle:
        text = handle.read()
    found = re.search(r"<style>\s*(.*?)\s*</style>", text, re.S)
    if not found:
        raise SystemExit("no inline <style> in " + path)
    return found.group(1)


with open(sys.argv[1], encoding="utf-8") as handle:
    page = handle.read()
assert "Stop fb-test-999?" in page, "confirmation heading missing"
assert style(sys.argv[1]) == style(sys.argv[2]), \
    "action page CSS differs from the dashboard's"
PY
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

bash "$TOOL" --root "$REPO" start --issue 999 --name test-999 \
    --branch test/999 --title 'Test issue' \
    --url 'https://example.test/issues/999' --no-start >/dev/null
WT="$REPO/.worktrees/test-999"

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

# The Chrome DevTools probe is answered without a token so the browser
# console stays quiet; it must stay empty instead of serving a file list.
code=$(curl -sS --max-time 10 -o "$TMP/devtools.json" -w '%{http_code}' \
    "$base/.well-known/appspecific/com.chrome.devtools.json" || true)
check test "$code" = 204
check test ! -s "$TMP/devtools.json"

# 404 for a name the inventory does not know.
code=$(curl -sS --max-time 10 -o /dev/null -D "$TMP/h404" -w '%{http_code}' \
    -H "Authorization: Bearer $TOKEN" \
    "$base/api/session/nope/pane" || true)
check test "$code" = 404

# ---- the headers and the Host check, on the wire ----
# The page is interactive now, so the CSP travels as a header (a meta tag
# cannot express frame-ancestors or base-uri) and every response carries it,
# including the ones that exist only to say no.
port=${base##*:}
code=$(curl -sS --max-time 10 -o /dev/null -D "$TMP/h200" -w '%{http_code}' \
    -H "Authorization: Bearer $TOKEN" "$base/" || true)
check test "$code" = 200
check_security_headers "$TMP/h200"
code=$(curl -sS --max-time 10 -o /dev/null -D "$TMP/h401" -w '%{http_code}' \
    "$base/api/sessions" || true)
check test "$code" = 401
check_security_headers "$TMP/h401"
check_security_headers "$TMP/h404"

# A page on 127.0.0.1 is same-site with every other loopback port, and DNS
# rebinding can point a public name at 127.0.0.1, so only the names this
# server answers for are served. A foreign Host is 421 even without a token:
# the check runs before auth, so no route is reachable under that name.
code=$(curl -sS --max-time 10 -o /dev/null -D "$TMP/h421" -w '%{http_code}' \
    -H 'Host: evil.example' -H "Authorization: Bearer $TOKEN" \
    "$base/api/sessions" || true)
check test "$code" = 421
check_security_headers "$TMP/h421"
code=$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' \
    -H 'Host: evil.example' "$base/api/sessions" || true)
check test "$code" = 421
code=$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' \
    -H 'Host: evil.example' -X POST -H "Authorization: Bearer $TOKEN" \
    "$base/api/gc?dry=1" || true)
check test "$code" = 421

# The names that are this server: the bound loopback, localhost, and [::1].
for host in "127.0.0.1:$port" "localhost:$port" "[::1]:$port" "LOCALHOST"; do
    code=$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' \
        -H "Host: $host" -H "Authorization: Bearer $TOKEN" \
        "$base/api/sessions" || true)
    check test "$code" = 200
done

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

# ---- the served page's forms, nonce and Origin checks ----
# A browser gets the cookie from ?token= once and then posts the page's own
# forms. The nonce is per server, the Origin is this server's, and a stop
# takes two POSTs: the first renders a confirmation and changes nothing.
jar="$TMP/jar"
code=$(curl -sS --max-time 10 -c "$jar" -o "$TMP/page.html" \
    -w '%{http_code}' "$base/?token=$TOKEN" || true)
check test "$code" = 200
page=$(cat "$TMP/page.html")
check contains "$page" '<form method="post"'
check contains "$page" 'action="/api/session/test-999/stop"'
check contains "$page" 'action="/api/session/test-999/stop?graceful=1"'
check contains "$page" 'action="/api/gc?dry=1"'
check contains "$page" 'name="nonce"'
nonce=$(sed -n 's/.*name="nonce" value="\([^"]*\)".*/\1/p' \
    "$TMP/page.html" | head -n 1)
check test -n "$nonce"

# A cookie POST with no nonce is refused, not silently a no-op.
code=$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' \
    -b "$jar" -X POST -H "Origin: $base" --data 'confirm=1' \
    "$base/api/session/test-999/stop?confirm=1" || true)
check test "$code" = 403
check grep -qxF 'fb-test-999' "$FAKE_DIR/session"

# A valid nonce with a foreign Origin is refused too: another service on
# 127.0.0.1 is same-site for the cookie, so the nonce alone is not enough.
code=$(curl -sS --max-time 10 -o /dev/null -D "$TMP/h403" -w '%{http_code}' \
    -b "$jar" -X POST -H 'Origin: http://attacker.invalid' \
    --data-urlencode "nonce=$nonce" --data 'confirm=1' \
    "$base/api/session/test-999/stop?confirm=1" || true)
check test "$code" = 403
# The refusal carries the same headers: a 403 is still a page the browser
# will render, and framing it would be exactly the click it refuses.
check_security_headers "$TMP/h403"
check grep -qxF 'fb-test-999' "$FAKE_DIR/session"

# The stray-click guard: first POST renders the confirmation page and runs
# nothing, even with a valid nonce and this server's own Origin.
: >"$FAKE_DIR/killed"
code=$(curl -sS --max-time 30 -o "$TMP/confirm.html" -w '%{http_code}' \
    -b "$jar" -X POST -H "Origin: $base" \
    --data-urlencode "nonce=$nonce" \
    "$base/api/session/test-999/stop" || true)
check test "$code" = 200
# The heading and the shared stylesheet in one check, so the suite keeps its
# count: the page a stray click lands on is styled by the dashboard's CSS.
check same_stylesheet "$TMP/confirm.html" "$TMP/page.html"
check contains "$(cat "$TMP/confirm.html")" '?confirm=1'
check grep -qxF 'fb-test-999' "$FAKE_DIR/session"
check test ! -s "$FAKE_DIR/killed"

# The second click runs the action once and answers 303 to /.
code=$(curl -sS --max-time 30 -o /dev/null -D "$TMP/stop.headers" \
    -w '%{http_code}' -b "$jar" -X POST -H "Origin: $base" \
    --data-urlencode "nonce=$nonce" --data 'confirm=1' \
    "$base/api/session/test-999/stop?confirm=1" || true)
check test "$code" = 303
check test "$(sed -n 's/\r$//; s/^[Ll]ocation: //p' "$TMP/stop.headers" |
    head -n 1)" = /
# form-action 'self' does not break the POST -> 303 flow, and the redirect
# carries the headers too.
check_security_headers "$TMP/stop.headers"
check test "$(grep -cxF 'fb-test-999' "$FAKE_DIR/killed")" = 1
check test "$(grep -cxF 'fb-test-999' "$FAKE_DIR/session" || true)" = 0

# After the redirect the card reads stopped and offers no Stop button.
code=$(curl -sS --max-time 10 -b "$jar" -o "$TMP/after.html" \
    -w '%{http_code}' "$base/" || true)
check test "$code" = 200
check contains "$(cat "$TMP/after.html")" '<span class="badge">stopped</span>'
check test "$(grep -cF 'action="/api/session/test-999/stop"' \
    "$TMP/after.html" || true)" = 0

# The gc form runs a dry run, redirects to a one-shot report URL, and the
# report is shown once: a refresh is the plain dashboard, not a replay.
fake_session test-999 "$IDLE_PANE" "$(($(date +%s) - 30))"
code=$(curl -sS --max-time 10 -H "Authorization: Bearer $TOKEN" \
    -o "$TMP/page2.html" -w '%{http_code}' "$base/" || true)
check test "$code" = 200
check contains "$(cat "$TMP/page2.html")" 'action="/api/gc?dry=1"'
code=$(curl -sS --max-time 30 -o /dev/null -D "$TMP/gc.headers" \
    -w '%{http_code}' -b "$jar" -X POST -H "Origin: $base" \
    --data-urlencode "nonce=$nonce" "$base/api/gc?dry=1" || true)
check test "$code" = 303
gc_location=$(sed -n 's/\r$//; s/^[Ll]ocation: //p' "$TMP/gc.headers" |
    head -n 1)
check contains "$gc_location" '/?gc='
code=$(curl -sS --max-time 10 -b "$jar" -o "$TMP/gc.html" \
    -w '%{http_code}' "$base$gc_location" || true)
check test "$code" = 200
check contains "$(cat "$TMP/gc.html")" 'gc --dry-run</h2>'
check contains "$(cat "$TMP/gc.html")" 'skip name=test-999 reason=idle'
code=$(curl -sS --max-time 10 -b "$jar" -o "$TMP/gc2.html" \
    -w '%{http_code}' "$base$gc_location" || true)
check test "$code" = 200
check test "$(grep -cF 'skip name=test-999 reason=idle' \
    "$TMP/gc2.html" || true)" = 0

# A bearer-token POST with no nonce still works: the curl path from #22.
code=$(curl -sS --max-time 30 -o /dev/null -w '%{http_code}' -X POST \
    -H "Authorization: Bearer $TOKEN" \
    "$base/api/session/test-999/stop" || true)
check test "$code" = 202

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

start_server ro --read-only --allow-host agents.test || true
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
# The read-only page carries no form at all, so a reader is never offered a
# button whose only outcome is that 403.
code=$(curl -sS --max-time 10 -o "$TMP/ro-page.html" -w '%{http_code}' \
    -H "Authorization: Bearer $TOKEN" "$ro_base/" || true)
check test "$code" = 200
check test "$(grep -cF '<form' "$TMP/ro-page.html" || true)" = 0
# --allow-host adds a proxy's own name, and only that name: it is how a
# proxy that keeps its Host keeps working with the 421 check.
code=$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' \
    -H 'Host: agents.test' -H "Authorization: Bearer $TOKEN" \
    "$ro_base/api/sessions" || true)
check test "$code" = 200
code=$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' \
    -H 'Host: other.test' -H "Authorization: Bearer $TOKEN" \
    "$ro_base/api/sessions" || true)
check test "$code" = 421
code=$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' -X POST \
    -H "Authorization: Bearer $TOKEN" "$ro_base/api/gc?dry=1" || true)
check test "$code" = 403
# auth still comes first: no token is 401 even in read-only mode
code=$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' -X POST \
    "$ro_base/api/session/test-999/stop" || true)
check test "$code" = 401

check stop_server "$SERVER_PID" "$ro_base"

# ---- --source concord drives the page and both JSON routes ----
# A live pane and a disagreeing Concord export: the page must render the
# chosen source, and the pane route must name the loser instead of hiding it.
mkdir -p "$WT/.concord"
printf '*\n' >"$WT/.concord/.gitignore"
cat >"$WT/.concord/WORK_STATE.json" <<'EOF'
{
  "generated_at": "2026-11-27T10:00:00.000Z",
  "presence": [],
  "tasks": [
    {
      "task_id": "T68",
      "status": "blocked",
      "version": 1,
      "updated_at": "2026-11-27T10:00:00.000Z",
      "branch": "test/999"
    }
  ]
}
EOF
fake_session test-999 "$IDLE_PANE" "$(($(date +%s) - 30))"
start_server concord --source concord || true
check test -n "$SERVER_PID"
check test "$(sed -n 's/^source=//p' "$TMP/concord.out")" = concord
code=$(curl -sS --max-time 10 -o "$TMP/concord.json" -w '%{http_code}' \
    -H "Authorization: Bearer $TOKEN" "$SERVER_BASE/api/sessions" || true)
check test "$code" = 200
check contains "$(cat "$TMP/concord.json")" '"state": "blocked"'
check contains "$(cat "$TMP/concord.json")" '"source": "concord"'
code=$(curl -sS --max-time 10 -o "$TMP/concord-pane.json" -w '%{http_code}' \
    -H "Authorization: Bearer $TOKEN" \
    "$SERVER_BASE/api/session/test-999/pane" || true)
check test "$code" = 200
check json_ok "$(cat "$TMP/concord-pane.json")"
check contains "$(cat "$TMP/concord-pane.json")" '"session_state": "blocked"'
check contains "$(cat "$TMP/concord-pane.json")" '"source": "concord"'
check contains "$(cat "$TMP/concord-pane.json")" '"concord_status": "blocked"'
check contains "$(cat "$TMP/concord-pane.json")" '"loser_state": "idle"'
code=$(curl -sS --max-time 10 -o "$TMP/concord-page.html" -w '%{http_code}' \
    -H "Authorization: Bearer $TOKEN" "$SERVER_BASE/" || true)
check test "$code" = 200
check contains "$(cat "$TMP/concord-page.html")" '<span class="badge">blocked</span>'
check stop_server "$SERVER_PID" "$SERVER_BASE"
rm -rf "$WT/.concord"

if [ "$failed" -ne 0 ]; then
    printf '%d/%d gui checks failed\n' "$failed" "$total" >&2
    exit 1
fi
printf 'ok %d gui checks\n' "$total"
