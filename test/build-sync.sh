#!/usr/bin/env bash
# Area: the shipped artifact is generated from src/ (#139). The tool stays one
# file for the copy-and-chmod install; the parts exist so a change touches one
# area instead of a 4,000-line file. A stale artifact is the failure this area
# exists for: it would ship code the tests in src/ never saw.

# shellcheck shell=bash
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

if out=$(bash "$ROOT/build.sh" --check 2>&1); then rc=0; else rc=$?; fi
check test "$rc" -eq 0
check contains "$out" 'build=ok'
check test -x "$ROOT/spawn-freebuff-agent"
check test "$(head -n 1 "$ROOT/spawn-freebuff-agent")" = '#!/usr/bin/env bash'

# A build to a separate path is what a reviewer or a test can compare, without
# rewriting the tree: it must be the same bytes the artifact carries.
if bash "$ROOT/build.sh" --out "$TMP/artifact" >"$TMP/build.out" 2>&1; then rc=0; else rc=$?; fi
check test "$rc" -eq 0
check contains "$(cat "$TMP/build.out")" 'build=ok out='
check cmp -s "$TMP/artifact" "$ROOT/spawn-freebuff-agent"
check bash -n "$TMP/artifact"

# The parts are the source of truth, and the map in the artifact names them.
check test -s "$ROOT/src/00-head.sh"
check contains "$(cat "$ROOT/src/00-head.sh")" 'Map. The file is one unit'
check contains "$(cat "$ROOT/src/10-argv.sh")" '# ---- argv and usage ----'
check test -s "$ROOT/src/85-start.sh"
check test -s "$ROOT/src/99-dispatch.sh"

# A stale artifact is a hard error, so the check must fail when it is stale.
# Copy one part with a trailing edit, point the check at a scratch copy of the
# tree, and prove it refuses: the check is only useful if it can fail.
mkdir -p "$TMP/stale/src"
cp "$ROOT/build.sh" "$TMP/stale/build.sh"
cp "$ROOT/spawn-freebuff-agent" "$TMP/stale/spawn-freebuff-agent"
cp "$ROOT/src/"*.sh "$TMP/stale/src/"
printf '\n# stale marker\n' >>"$TMP/stale/src/99-dispatch.sh"
if bash "$TMP/stale/build.sh" --check >"$TMP/stale.out" 2>&1; then rc=0; else rc=$?; fi
check test "$rc" -eq 1
check contains "$(cat "$TMP/stale.out")" 'build=stale'
check contains "$(cat "$TMP/stale.out")" 'run ./build.sh'
