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
check contains "$out" '"running": true'
check contains "$out" '"input": "canonical"'
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
