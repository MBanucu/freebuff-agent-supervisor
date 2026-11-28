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
#   ./build.sh --edited REF fail when the artifact changed but no part did
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
  ./build.sh --edited REF fail when the artifact changed against REF but no
                          src/ part did, naming the part the edit belongs in
  ./build.sh --out FILE   write the build to FILE instead
USAGE
}

mode=build
out=$artifact
edited_ref=''
while [ $# -gt 0 ]; do
    case "$1" in
        --check) mode=check; shift ;;
        --edited)
            mode=edited
            edited_ref=${2:-}
            [ -n "$edited_ref" ] || die '--edited needs a ref'
            shift 2
            ;;
        --out)
            out=${2:-}
            [ -n "$out" ] || die '--out needs a file'
            shift 2
            ;;
        -h|--help) usage; exit 0 ;;
        *) die "unsupported argument: $1" ;;
    esac
done

# A commit may not hand-edit the generated file (#140). `--check` catches a
# stale artifact, but an edit that also skips src/ reads as "run ./build.sh",
# which is not the fix. This mode says which part the edit belongs in. It only
# inspects names and line numbers, so it is cheap and needs no build; a change
# that touches any part passes, and so does one that leaves the artifact alone
# (a rebuild is a mode-only or empty diff there).
if [ "$mode" = edited ]; then
    repo=$(git -C "$here" rev-parse --show-toplevel 2>/dev/null) ||
        die 'not a git checkout: --edited needs history'
    # The merge base is what this branch added, not what main did meanwhile;
    # a shallow clone without it falls back to the ref itself.
    base=$(git -C "$repo" merge-base "$edited_ref" HEAD 2>/dev/null) || base=''
    [ -n "$base" ] || base=$(git -C "$repo" rev-parse --verify --quiet "$edited_ref^{commit}") ||
        die "unknown base: $edited_ref"
    changed=$(git -C "$repo" diff --name-only "$base" 2>/dev/null) || die "cannot diff $base"
    if ! printf '%s\n' "$changed" | grep -qx 'spawn-freebuff-agent'; then
        printf 'edited=ok artifact=unchanged\n'
        exit 0
    fi
    if printf '%s\n' "$changed" | grep -q '^src/.*\.sh$'; then
        printf 'edited=ok artifact=spawn-freebuff-agent parts-changed=yes\n'
        exit 0
    fi
    # The edit's new-file line numbers pick the banner above them, and the
    # banner is the first line of its part, so the message names the file.
    starts=$(git -C "$repo" diff -U0 "$base" -- spawn-freebuff-agent 2>/dev/null |
        sed -n 's/^@@ -[0-9]*\(,[0-9]*\)\? +\([0-9]*\).*/\2/p' || true)
    banners=''
    if [ -n "$starts" ]; then
        banners=$(printf '%s\n' "$starts" | awk -v lines="$(printf '%s' "$starts")" '
            BEGIN { n = split(lines, want, "\n") }
            /^# ---- / { banner = $0 }
            { while (k < n && NR >= want[k + 1]) { k++; print banner } }
            END { while (k < n) { k++; print banner } }
        ' "$artifact")
    fi
    parts=''
    while IFS= read -r banner; do
        [ -n "$banner" ] || continue
        for part in "$here"/src/*.sh; do
            if [ "$(head -n 1 "$part")" = "$banner" ]; then
                parts+=" src/$(basename "$part")"
                break
            fi
        done
    done <<<"$banners"
    printf 'build=artifact-edited artifact=%s\n' "$(basename "$artifact")" >&2
    printf 'the artifact is generated: edit a src/ part and run ./build.sh\n' >&2
    if [ -n "$parts" ]; then
        printf 'the change falls in:%s\n' "$parts" >&2
    else
        printf 'the change falls in: src/00-head.sh (before the first banner)\n' >&2
    fi
    exit 1
fi

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
