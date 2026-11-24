#!/usr/bin/env bash
# Device-free checks for spawn-freebuff-agent. A temporary git repo
# stands in for the project; no tmux, Freebuff, gh or phone is needed.
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
check test ! -e "$REPO/.worktrees/test-999"

bash "$TOOL" --root "$REPO" start --issue 999 --name test-999 \
    --branch test/999 --title 'Test issue' \
    --url 'https://example.test/issues/999' --no-start --sdk-dir "$TMP/sdk" >/dev/null

WT="$REPO/.worktrees/test-999"
check test -d "$WT"
check test -f "$WT/.task.md"
check contains "$(cat "$WT/.task.md")" 'issue #999'
check contains "$(cat "$WT/.task.md")" 'test/999'
check test -f "$WT/local.properties"
check contains "$(cat "$WT/local.properties")" "sdk.dir=$TMP/sdk"
check test "$(git -C "$WT" branch --show-current)" = test/999
check test -z "$(git -C "$WT" status --short)"

check grep -qxF '.task.md' "$REPO/.git/info/exclude"
check grep -qxF 'local.properties' "$REPO/.git/info/exclude"
check grep -qxF '.worktrees/' "$REPO/.git/info/exclude"

out=$(bash "$TOOL" --root "$REPO" status --no-gh test-999)
check contains "$out" 'branch=test/999'
check contains "$out" 'running=no'
check contains "$out" 'dirty=no'

out=$(bash "$TOOL" --root "$REPO" list)
check contains "$out" 'test-999'

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
