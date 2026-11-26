#!/usr/bin/env bash
# Device-free checks for spawn-freebuff-agent. test/lib.sh owns the temp repo,
# the fake tmux/stty/freebuff and the fixtures; each area file owns one section
# of the suite, so a failure points at a small file and an area can be run on
# its own:
#
#     . test/lib.sh && . test/state-evidence.sh
#
# No Freebuff, gh, network or phone is needed.
set -euo pipefail

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd) || exit 1
# shellcheck source=test/lib.sh
. "$HERE/test/lib.sh"

for area in cli-json snapshot-gui state-evidence lifecycle-sessions \
    brief-refusals readiness-submission wait-actions; do
    # shellcheck source=/dev/null
    . "$HERE/test/$area.sh"
done

if [ "$failed" -ne 0 ]; then
    printf '%d/%d checks failed\n' "$failed" "$total" >&2
    exit 1
fi
printf 'ok %d checks\n' "$total"
