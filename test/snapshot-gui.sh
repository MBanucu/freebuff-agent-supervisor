#!/usr/bin/env bash
# Area: the static snapshot and its escaping and watch mode (#18).

# shellcheck shell=bash
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

[ -d "$WT" ] || bash "$TOOL" --root "$REPO" start --issue 999 --name test-999 \
    --branch test/999 --title 'Test issue' \
    --url 'https://example.test/issues/999' --no-start >/dev/null
rm -f "$WT/.agent-result" "$WT/.refusal"

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
# the result file outranks the busy pane: blocked is red, working is amber
check contains "$SNAP" 'card state-failed'
check contains "$SNAP" 'card state-working'
# a done card carries no idle line; a live working card still carries one (#57)
card_of() {
    awk -v want="<h2>$1</h2>" '
        /<article class="card/ { buf=$0; hit=0; next }
        { buf=buf "\n" $0 }
        index($0, want) { hit=1 }
        /<\/article>/ { if (hit) print buf; buf=""; hit=0 }
    '
}
done_card=$(printf '%s\n' "$SNAP" | card_of test-999)
check test -n "$done_card"
check test "$(printf '%s' "$done_card" | grep -c '<dt>idle</dt>')" = 0
live_card=$(printf '%s\n' "$SNAP" | card_of test-two)
check test -n "$live_card"
check test "$(printf '%s' "$live_card" | grep -c '<dt>idle</dt>')" = 1
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
# The later areas count worktrees and sessions; leave only test-999 behind.
git -C "$REPO" worktree remove --force "$REPO/.worktrees/test-two" \
    >/dev/null 2>&1 || true
