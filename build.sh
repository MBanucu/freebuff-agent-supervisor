#!/usr/bin/env bash
# Build the shipped artifact from src/.
#
# `spawn-freebuff-agent` is one file on purpose: Install says copy it and
# `chmod +x`. Editing one 4,000-line file, and resolving a stale branch in it,
# is what src/ is for: this script concatenates the parts, in the order listed
# below, into that one shipped file byte for byte. The artifact keeps its
# one-file contract, and a change touches one small area.
#
#   ./build.sh              rewrite spawn-freebuff-agent
#   ./build.sh --check      fail when the artifact is not what src/ builds
#   ./build.sh --out FILE   write the build elsewhere (review, tests)
#
# The parts are listed, not globbed: a new part has to be added here, and a
# missing one fails the build instead of being silently skipped.
set -euo pipefail

PARTS=(
    00-head.sh
    10-argv.sh
    20-discovery.sh
    30-preflight.sh
    40-wakelock.sh
    50-refusal.sh
    60-json.sh
    70-evidence.sh
    75-brief.sh
    78-picker.sh
    79-model-key.sh
    80-mirror.sh
    85-start.sh
    88-views.sh
    90-watch.sh
    92-gui.sh
    94-send.sh
    99-dispatch.sh
)

here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd) || exit 1
artifact="$here/spawn-freebuff-agent"

die() {
    printf 'build.sh: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'USAGE'
Build the one shipped file from src/.

  ./build.sh              rewrite spawn-freebuff-agent
  ./build.sh --check      compare it with src/ and fail on a difference
  ./build.sh --out FILE   write the build to FILE instead
USAGE
}

mode=build
out=$artifact
while [ $# -gt 0 ]; do
    case "$1" in
        --check) mode=check; shift ;;
        --out)
            out=${2:-}
            [ -n "$out" ] || die '--out needs a file'
            shift 2
            ;;
        -h|--help) usage; exit 0 ;;
        *) die "unsupported argument: $1" ;;
    esac
done

tmp=$(mktemp) || die 'mktemp failed'
trap 'rm -f "$tmp"' EXIT

for part in "${PARTS[@]}"; do
    [ -f "$here/src/$part" ] || die "missing part: src/$part (add it to PARTS in this file)"
    cat "$here/src/$part" >>"$tmp"
done

# The artifact has to stay runnable, and the shebang is the first byte of it:
# a build that reordered a part ahead of it would ship a file that cannot run.
[ "$(head -n 1 "$tmp")" = '#!/usr/bin/env bash' ] ||
    die 'the first part must start with the shebang'
bash -n "$tmp" || die 'the concatenated parts do not parse'

if [ "$mode" = check ]; then
    if cmp -s "$tmp" "$artifact"; then
        printf 'build=ok artifact=%s parts=%s\n' "$(basename "$artifact")" "${#PARTS[@]}"
        exit 0
    fi
    printf 'build=stale artifact=%s\n' "$(basename "$artifact")" >&2
    diff -u "$artifact" "$tmp" | head -40 >&2 || true
    printf 'run ./build.sh and commit the result\n' >&2
    exit 1
fi

cat "$tmp" >"$out"
chmod +x "$out"
printf 'build=ok out=%s parts=%s\n' "$out" "${#PARTS[@]}"
