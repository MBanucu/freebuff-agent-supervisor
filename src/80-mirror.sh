# ---- the issue mirror ----
# Moving the status:* label and leaving the one comment on the issue; every
# failure here is swallowed, so a flaky API cannot cost a run.
gh_state_color() {
    # gh_state_color STATE -> label colour, so the four states look different
    # on the issues page instead of one grey label moving around.
    case "$1" in
        working) printf 'fbca04' ;;
        blocked) printf 'd93f0b' ;;
        done) printf '0e8a16' ;;
        failed) printf 'b60205' ;;
        *) printf 'ededed' ;;
    esac
}

gh_state() {
    # gh_state WORKTREE STATE [SUMMARY] -> move the issue's status:* label to
    # STATE and, when SUMMARY is given, leave it as a comment. The session is
    # the authority; GitHub is a mirror of it, so every failure here is
    # swallowed: a flaky API must never cost a vendor slot or a worktree.
    local wt=$1 state=$2 summary=${3:-} f issue slug cur lab
    local -a args=()
    f="$wt/$GH_STATE_FILE"
    [ -f "$f" ] || return 0
    [ "${FREEBUFF_GH_SYNC:-1}" = 0 ] && return 0
    command -v "${GH_BIN:-gh}" >/dev/null 2>&1 || return 0
    issue=$(sed -n 's/^issue=//p' "$f" 2>/dev/null | head -n 1)
    slug=$(sed -n 's/^slug=//p' "$f" 2>/dev/null | head -n 1)
    [ -n "$issue" ] && [ -n "$slug" ] || return 0
    lab="status:$state"
    "${GH_BIN:-gh}" label create "$lab" -R "$slug" --force \
        --color "$(gh_state_color "$state")" --description "subagent $state" \
        >/dev/null 2>&1 || true
    # One status label at a time: the current set is read first so the others
    # can be removed without guessing whether they exist.
    cur=$("${GH_BIN:-gh}" issue view "$issue" -R "$slug" --json labels \
        --jq '[.labels[].name|select(startswith("status:"))]|join(" ")' \
        2>/dev/null || true)
    local l
    for l in $cur; do
        [ "$l" = "$lab" ] || args+=(--remove-label "$l")
    done
    "${GH_BIN:-gh}" issue edit "$issue" -R "$slug" ${args[@]+"${args[@]}"} \
        --add-label "$lab" >/dev/null 2>&1 || true
    [ -z "$summary" ] || "${GH_BIN:-gh}" issue comment "$issue" -R "$slug" \
        --body "$summary" >/dev/null 2>&1 || true
    return 0
}

