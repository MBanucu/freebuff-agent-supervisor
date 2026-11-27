#!/usr/bin/env bash
# Area: the CLI surface, the exclude list, --json and the remaining flags.

# shellcheck shell=bash
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

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

# ---- the preflight (#98) ----

# A healthy run says so once per check, before the plan, and ends on ok.
out=$(bash "$TOOL" --root "$REPO" start --issue 994 --name test-preflight \
    --branch test/preflight --title T --url U --dry-run)
check contains "$out" 'preflight=tmux ok'
check contains "$out" 'preflight=freebuff ok'
check contains "$out" 'preflight=stty ok'
check contains "$out" 'preflight=git ok'
check contains "$out" 'preflight=gh ok'
check contains "$out" 'preflight=ok'
check test "$(printf '%s\n' "$out" | grep -c '^preflight=')" = 6
check contains "$out" 'worktree='
check contains "$(bash "$TOOL" --help 2>&1)" '--no-check'

# A Termux-shaped PATH without tmux names the package that installs it, on a
# dry run and on a real start, and neither leaves a worktree or a branch.
mkdir -p "$TMP/termux-bin" "$TMP/nocache"
for cmd in bash git stty sha256sum cut sed sleep; do
    found=$(command -v "$cmd" || true)
    [ -z "$found" ] || ln -sf "$found" "$TMP/termux-bin/$cmd"
done
termux_start() {
    # termux_start ARGS... -> one start on a Termux-shaped PATH: the commands
    # the tool needs, no tmux, PREFIX set and no tmux cache to fall back on.
    env -u FREEBUFF_TMUX PREFIX=/data/data/com.termux/files/usr \
        XDG_CACHE_HOME="$TMP/nocache" PATH="$TMP/termux-bin" \
        FREEBUFF_BIN="$TMP/bin/freebuff" bash "$TOOL" --root "$REPO" "$@"
}
out=$(termux_start start --issue 89 --name test-termux --branch test/termux \
    --title T --url U --dry-run 2>&1) || true
check contains "$out" 'preflight=tmux missing=tmux hint=pkg install tmux'
check contains "$out" 'preflight=failed'
check test ! -e "$REPO/.worktrees/test-termux"
out=$(termux_start start --issue 89 --name test-termux --branch test/termux \
    --title T --url U 2>&1) || true
check contains "$out" 'hint=pkg install tmux'
check contains "$out" 'start: tmux not found'
check test ! -e "$REPO/.worktrees/test-termux"
check test ! -e "$REPO/.git/refs/heads/test/termux"

# A client that exists but cannot execute is named with its exit status: on
# Termux that is the glibc binary and its missing loader, and the old path
# reported it as a 120s readiness timeout.
printf '#!/usr/bin/env bash\nexit 127\n' >"$TMP/bin/freebuff-127"
printf '#!/usr/bin/env bash\nsleep 30\n' >"$TMP/bin/freebuff-hang"
chmod +x "$TMP/bin/freebuff-127" "$TMP/bin/freebuff-hang"
fake_clear
out=$(FREEBUFF_BIN="$TMP/bin/freebuff-127" bash "$TOOL" --root "$REPO" start \
    --issue 98 --name test-broken --branch test/broken --title T --url U 2>&1) || true
check contains "$out" 'preflight=freebuff error=exit_127'
check contains "$out" 'exits 127'
check test ! -e "$REPO/.worktrees/test-broken"
check test -z "$(grep -F 'fb-test-broken' "$FAKE_DIR/session" 2>/dev/null || true)"
out=$(FREEBUFF_PREFLIGHT_TIMEOUT=1 FREEBUFF_BIN="$TMP/bin/freebuff-hang" \
    bash "$TOOL" --root "$REPO" start --issue 97 --name test-hang \
    --branch test/hang --title T --url U 2>&1) || true
check contains "$out" 'preflight=freebuff error=timeout'
check test ! -e "$REPO/.worktrees/test-hang"

# gh is optional: a miss is reported, not fatal, because the run can still be
# named and labelled with --title/--url or --no-gh.
out=$(GH_BIN="$TMP/no-gh" bash "$TOOL" --root "$REPO" start --issue 95 \
    --name test-nogh --branch test/nogh --title T --url U --dry-run)
check contains "$out" 'preflight=gh missing=gh hint=install gh optional=yes'
check contains "$out" 'preflight=ok'
check contains "$out" 'worktree='

# --no-check and FREEBUFF_SKIP_PREFLIGHT=1 keep the old late lookup: no probe,
# no preflight line, and a dry run still prints the plan.
out=$(FREEBUFF_BIN="$TMP/bin/freebuff-127" bash "$TOOL" --root "$REPO" start \
    --issue 96 --name test-nocheck --branch test/nocheck --title T --url U \
    --dry-run --no-check)
case "$out" in *preflight=*) check false ;; *) check true ;; esac
check contains "$out" 'worktree='
out=$(FREEBUFF_SKIP_PREFLIGHT=1 FREEBUFF_BIN="$TMP/bin/freebuff-127" \
    bash "$TOOL" --root "$REPO" start --issue 96 --name test-nocheck \
    --branch test/nocheck --title T --url U --dry-run)
case "$out" in *preflight=*) check false ;; *) check true ;; esac

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
check grep -qxF '.supervisor-hours' "$REPO/.git/info/exclude"

# The JSON section reads the last recorded watcher: seed a dead pid so it
# is deterministic when this area runs alone.
printf 'autostop=pid:999999\n' >>"$WT/.supervisor.log"

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
# the result file outranks the pane for test-999: blocked is not done
check contains "$out" '"state": "blocked"'
check contains "$out" '"state": "idle"'
check contains "$out" '"result": "blocked"'
# a terminal run carries no idle time; the live orphan still has one (#57)
check test "$(printf '%s\n' "$out" | grep -c '"idle_seconds": null')" = 1
check test "$(printf '%s\n' "$out" | grep -c '"idle_seconds": [0-9]')" = 1
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
# this area runs with the real stty and a tty fixture that is a plain file,
# so stty cannot read it: the mode is unknown, not a guessed canonical (#100).
check contains "$out" '"running": true'
check contains "$out" '"input": "unknown"'
check contains "$out" '"session_state": "blocked"'
check contains "$out" '"idle_seconds": null'
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

rm -f "$WT/.agent-result"
fake_clear

# ---- the hours ledger (#108) ----

# A live footer reading is current: status shows it without an age, appends
# exactly one line to the ledger and names the source in JSON.
rm -f "$REPO/.supervisor-hours"
fake_session test-999 "$HOURS_FOOTER_PANE"
out=$(bash "$TOOL" --root "$REPO" status --json --no-gh test-999)
check json_ok "$out"
check contains "$out" '"hours": {'
check contains "$out" '"value": "3/4"'
check contains "$out" '"age_seconds": 0'
check contains "$out" '"source": "footer"'
check test "$(grep -c . "$REPO/.supervisor-hours" || true)" = 1
check contains "$(cat "$REPO/.supervisor-hours")" \
    'hours=3/4 source=footer session=fb-test-999'
out=$(bash "$TOOL" --root "$REPO" status --no-gh test-999)
check contains "$out" 'hours=3/4'
check test -z "$(printf '%s\n' "$out" | grep '^hours=.*age=' || true)"

# Without a live reading the ledger's last line is shown with its age, so
# 47 minutes old can never read as the current number.
printf 'ts=%s hours=1/2 source=panel session=fb-old\n' \
    "$(($(date +%s) - 2820))" >"$REPO/.supervisor-hours"
fake_clear
out=$(bash "$TOOL" --root "$REPO" status --no-gh test-999)
check contains "$out" 'hours=1/2 age=47m'
out=$(bash "$TOOL" --root "$REPO" status --json --no-gh test-999)
check contains "$out" '"value": "1/2"'
check contains "$out" '"source": "panel"'
check test "$(printf '%s\n' "$out" | sed -n 's/.*"age_seconds": \([0-9][0-9]*\).*/\1/p')" -ge 2820
check test "$(printf '%s\n' "$out" | sed -n 's/.*"age_seconds": \([0-9][0-9]*\).*/\1/p')" -le 2880

# No history at all is `-` and nulls, not `unknown` dressed as a reading.
rm -f "$REPO/.supervisor-hours"
out=$(bash "$TOOL" --root "$REPO" status --json --no-gh test-999)
check contains "$out" '"value": null'
check test "$(printf '%s\n' "$out" | grep -c '"age_seconds": null')" = 1
check contains "$out" '"source": null'
out=$(bash "$TOOL" --root "$REPO" status --no-gh test-999)
check contains "$out" 'hours=-'

# sessions --json carries the same object per row, and the live read lands in
# the ledger exactly once.
fake_session test-999 "$HOURS_FOOTER_PANE"
out=$(bash "$TOOL" --root "$REPO" sessions --json --no-gh)
check json_ok "$out"
check contains "$out" '"hours": {'
check contains "$out" '"value": "3/4"'
check contains "$out" '"source": "footer"'
check test "$(grep -c . "$REPO/.supervisor-hours" || true)" = 1

rm -f "$REPO/.supervisor-hours"
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
# The next area counts worktrees, so leave the repo as this area found it.
git -C "$REPO" worktree remove --force "$REPO/.worktrees/test-custom" \
    >/dev/null 2>&1 || true

check contains "$(bash "$TOOL" --help 2>&1)" 'start'
check contains "$(bash "$TOOL" --help 2>&1)" 'gui --serve'
# help is about the tool, not a checkout: it answers outside a git repository
out=$(CDPATH='' cd -- "$TMP" && bash "$TOOL" --help 2>&1)
check contains "$out" '--prompt TEXT'
