# ---- status, list and sessions ----
# The three read views and the inventory helpers they share.
launch_branch() {
    # launch_branch WORKTREE -> the branch the launch recorded, or empty.
    # `.supervisor-gh` is written by start when gh sync is on; `.task.md`
    # always names the branch the worktree was created on. A worktree whose
    # HEAD is detached cannot answer from git, so this is the record that keeps
    # `HEAD` out of the inventory after a retry (#121).
    local wt="$1" file branch=''
    file="$wt/$GH_STATE_FILE"
    if [ -f "$file" ]; then
        branch=$(sed -n 's/^branch=//p' "$file" | head -n 1 || true)
    fi
    file="$wt/.task.md"
    if [ -z "$branch" ] && [ -f "$file" ]; then
        branch=$(sed -n 's/^Repo: .*Branch: `\([^`]*\)`.*$/\1/p' "$file" |
            head -n 1 || true)
    fi
    printf '%s' "$branch"
}

worktree_branch() {
    # worktree_branch WORKTREE -> the branch to report. The worktree's HEAD
    # wins; a detached HEAD (rev-parse answers `HEAD`) or an unreadable one
    # falls back to the launch record, so a retry does not turn the column
    # into `HEAD` while the branch is still the one the work belongs to.
    local branch
    branch=$(git -C "$1" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
    case "$branch" in
        ''|HEAD) branch=$(launch_branch "$1") ;;
    esac
    printf '%s' "${branch:-?}"
}

print_explanation() {
    # print_explanation BLOCK -> the classifier's decision as `explain:` lines,
    # including every marker that was checked and the pane it looked at.
    local block="$1" line win='' in_pane=0 rule
    while IFS= read -r line; do
        case "$line" in
            state=*) ;;
            source=*) printf 'explain: source=%s\n' "${line#source=}" ;;
            turn_state=*) printf 'explain: turn_state=%s\n' "${line#turn_state=}" ;;
            turn_outcome=*)
                [ -z "${line#turn_outcome=}" ] ||
                    printf 'explain: turn_outcome=%s\n' "${line#turn_outcome=}"
                ;;
            turn_log=*) printf 'explain: turn_log=%s\n' "${line#turn_log=}" ;;
            rule=*)
                rule=${line#rule=}
                printf 'explain: rule=%s\n' "$rule"
                [ "$rule" != no-rule-matched ] ||
                    printf 'explain: no rule matched the window\n'
                ;;
            matched=*)
                [ -z "${line#matched=}" ] ||
                    printf 'explain: matched=%s\n' "${line#matched=}"
                ;;
            window_lines=*) win=${line#window_lines=} ;;
            window_sha256=*)
                [ -z "${line#window_sha256=}" ] ||
                    printf 'explain: window=%s lines sha256=%s\n' \
                        "$win" "${line#window_sha256=}"
                ;;
            stable_scans=*) printf 'explain: stable_scans=%s\n' "${line#stable_scans=}" ;;
            check:*) printf 'explain: %s\n' "$line" ;;
            pane_begin) in_pane=1; printf 'explain: pane:\n' ;;
            pane_end) in_pane=0 ;;
            *) [ "$in_pane" = 0 ] || printf '  | %s\n' "$line" ;;
        esac
    done <<<"$block"
}

status() {
    # status NAME -> key=value lines by default, one JSON object with --json.
    # Both views come from the same fields: the JSON is a serialization of the
    # human output, not a second detection path. --explain adds the classifier's
    # decision line by line, from the same evidence block as --json.
    local name="" lines=25 no_gh=0 json=0 explain=0 window="$REFUSAL_WINDOW" source=pane
    while [ $# -gt 0 ]; do
        case "$1" in
            --lines) lines=${2:-}; shift 2 ;;
            --window) window=${2:-}; shift 2 ;;
            --source) source=${2:-}; shift 2 ;;
            --no-gh) no_gh=1; shift ;;
            --json) json=1; shift ;;
            --explain) explain=1; shift ;;
            -h|--help) usage; exit 0 ;;
            -*) die "status: unsupported argument: $1" ;;
            *) name=$1; shift ;;
        esac
    done
    [ -n "$name" ] || die "status: NAME is required"
    valid_name "$name" || die "status: invalid name"
    case "$lines" in
        ''|*[!0-9]*) die "status: --lines must be a number" ;;
    esac
    is_num "$window" || die "status: --window must be a number"
    case "$source" in
        pane|log|auto) ;;
        *) die "status: --source must be pane, log or auto" ;;
    esac

    local wt="$ROOT/.worktrees/$name" branch session tmux running=0 tty mode=unknown stty out
    local state rstate="" pane="" idle="" sstate="" last_commit dirty=no watcher=""
    local wake_lock="" hours=""
    local result_pr="" result_commit="" result_tests="" prs="" pr_json=null
    local evidence="" ev_rule="" ev_matched="" ev_lines="" ev_sha="" ev_scans="" ev_source=""
    local turn_evidence="" tstate="" tout="" turn_log=""
    [ -d "$wt" ] || die "status: no worktree at $wt"
    branch=$(worktree_branch "$wt")
    session="fb-$name"
    tmux=$(tmux_bin 2>/dev/null || true)

    # The turn log is a file, so it can be read with or without a session. The
    # human view shows its fields only when a source asks for it; --json always
    # carries the keys, null when there is no chat directory.
    if [ "$source" != pane ] || [ "$json" = 1 ]; then
        turn_evidence=$(turn_log_evidence "$name")
        tstate=$(evidence_field "$turn_evidence" turn_state)
        tout=$(evidence_field "$turn_evidence" turn_outcome)
        turn_log=$(evidence_field "$turn_evidence" turn_log)
        if [ "$json" = 1 ] && [ "$turn_log" != yes ]; then
            tstate=''
            tout=''
        fi
    fi

    if [ "$json" = 0 ]; then
        printf 'name=%s\nbranch=%s\nworktree=%s\nsession=%s\n' \
            "$name" "$branch" "$wt" "$session"
    fi

    state=$(result_state "$wt")
    [ -n "$state" ] || state=unknown
    watcher=$(watcher_state "$wt")
    wake_lock=$(wake_lock_state "$wt")
    if [ "$json" = 0 ]; then
        printf 'state=%s\n' "$state"
        printf 'watcher=%s\n' "$watcher"
        [ -z "$wake_lock" ] || printf 'wake_lock=%s\n' "$wake_lock"
    fi
    if [ -f "$wt/$RESULT_FILE" ]; then
        rstate=$state
        result_pr=$(result_key "$wt/$RESULT_FILE" pr)
        result_commit=$(result_key "$wt/$RESULT_FILE" commit)
        result_tests=$(result_key "$wt/$RESULT_FILE" tests)
        if [ "$json" = 0 ]; then
            [ -z "$result_pr" ] || printf 'result_pr=%s\n' "$result_pr"
            [ -z "$result_commit" ] || printf 'result_commit=%s\n' "$result_commit"
            [ -z "$result_tests" ] || printf 'result_tests=%s\n' "$result_tests"
        fi
    fi

    if [ -n "$tmux" ] && "$tmux" has-session -t "$session" 2>/dev/null; then
        running=1
        tty=$("$tmux" display-message -p -t "$session" '#{pane_tty}' 2>/dev/null || true)
        # raw/canonical are known only when stty can read the tty. A missing
        # tty, a missing stty or a tty stty cannot open stays unknown instead
        # of claiming canonical input the tool never observed.
        if [ -n "$tty" ]; then
            stty=$(stty_bin 2>/dev/null || true)
            if [ -n "$stty" ] && out=$("$stty" -a -F "$tty" 2>/dev/null); then
                if printf '%s' "$out" | grep -q -- '-icanon'; then
                    mode=raw
                else
                    mode=canonical
                fi
            fi
        fi
        evidence=$(classify_state "$name" "$window" "$source")
        sstate=$(evidence_field "$evidence" state)
        # Only a session that can still be idle has an idle time. The result
        # file outranks the pane, so `state` is the terminal answer even while
        # the TUI process stays alive; `session_state` carries the same verdict
        # on a branch that reports blocked and failed distinctly (#32).
        if ! state_is_terminal "$state" && ! state_is_terminal "$sstate"; then
            idle=$(idle_seconds "$name" || true)
        fi
        pane=$("$tmux" capture-pane -p -t "$session" -S "-$lines" 2>/dev/null || true)
        if [ "$json" = 0 ]; then
            printf 'running=yes\ninput=%s\n' "$mode"
            printf 'session_state=%s\n' "$sstate"
            if [ "$source" != pane ]; then
                printf 'turn_state=%s\nturn_outcome=%s\n' "$tstate" "$tout"
            fi
            [ "$explain" = 0 ] || print_explanation "$evidence"
            [ -z "$idle" ] || printf 'idle_seconds=%s\n' "$idle"
        fi
    else
        local sentence
        if [ "$source" != pane ]; then
            # The log outlives the TUI, so a stopped session can still name
            # its last turn; auto falls back to `missing` when there is none.
            evidence=$(classify_state "$name" "$window" "$source")
            sstate=$(evidence_field "$evidence" state)
        else
            sstate=missing
            sentence=$(refusal_recorded "$wt")
            # A recorded refusal outlives the session: start stops a refused
            # launch, but status must keep saying refused until stop clears it.
            if [ -n "$sentence" ]; then
                sstate=refused
                printf -v evidence 'state=%s\nsource=refusal\nrule=recorded-refusal\nmatched=%s\nwindow_lines=0\nwindow_sha256=\nstable_scans=0\ncheck: session (fb-%s): no\ncheck: recorded-refusal (%s): yes\npane_begin\npane_end\n' \
                    "$sstate" "$sentence" "$name" "$REFUSAL_FILE"
            else
                printf -v evidence 'state=missing\nsource=pane\nrule=no-session\nmatched=\nwindow_lines=0\nwindow_sha256=\nstable_scans=0\ncheck: session (fb-%s): no\npane_begin\npane_end\n' \
                    "$name"
            fi
        fi
        if [ "$json" = 0 ]; then
            printf 'running=no\nsession_state=%s\n' "$sstate"
            if [ "$source" != pane ]; then
                printf 'turn_state=%s\nturn_outcome=%s\n' "$tstate" "$tout"
            fi
            [ "$explain" = 0 ] || print_explanation "$evidence"
        fi
    fi

    # The hours reading is the live pane when it carries one, otherwise the
    # ledger's last line with its age. A live read is what this run observed;
    # a cached one is never printed without that age (#108).
    if hours_read "$session" "$pane"; then
        if [ "$HOURS_FRESH" = 1 ]; then
            hours="hours=$HOURS_VALUE"
        else
            hours="hours=$HOURS_VALUE age=$(hours_age_label "$HOURS_AGE")"
        fi
    else
        hours='hours=-'
    fi
    if [ "$json" = 0 ]; then
        printf '%s\n' "$hours"
    fi

    last_commit=$(git -C "$wt" log -1 --oneline 2>/dev/null || true)
    if [ -n "$(git -C "$wt" status --short 2>/dev/null || true)" ]; then
        dirty=yes
    else
        dirty=no
    fi
    if [ "$json" = 0 ]; then
        printf 'commit=%s\n' "$last_commit"
        printf 'dirty=%s\n' "$dirty"
    fi

    if [ "$no_gh" = 0 ]; then
        local slug
        slug=$(repo_slug || true)
        if [ -n "$slug" ] && command -v "${GH_BIN:-gh}" >/dev/null 2>&1; then
            prs=$("${GH_BIN:-gh}" pr list -R "$slug" --head "$branch" --state open \
                --json number,url,title \
                --jq '.[] | "pr=#\(.number) \(.url) \(.title)"' 2>/dev/null || true)
            if [ -n "$prs" ]; then
                if [ "$json" = 0 ]; then
                    printf '%s\n' "$prs"
                else
                    pr_json=$(pr_json_array "$prs")
                fi
            else
                if [ "$json" = 0 ]; then
                    printf 'pr=none\n'
                else
                    pr_json='[]'
                fi
            fi
        fi
    fi

    if [ "$json" = 0 ]; then
        # --explain already dumped the classified window, so the tail is not
        # repeated; without it the human view is unchanged.
        [ "$explain" = 1 ] || [ -z "$pane" ] || printf '%s\n' "$pane"
        return 0
    fi

    # The evidence object is additive: `rule` names the decision, `matched`
    # the line behind it, and the hash names the window, so an unknown pane can
    # be compared across scans. `unknown` remains the `state` placeholder for
    # "no result file" as before; the pane classifier's unknown is
    # `session_state`.
    ev_source=$(evidence_field "$evidence" source)
    ev_rule=$(evidence_field "$evidence" rule)
    ev_matched=$(evidence_field "$evidence" matched)
    ev_lines=$(evidence_field "$evidence" window_lines)
    ev_sha=$(evidence_field "$evidence" window_sha256)
    ev_scans=$(evidence_field "$evidence" stable_scans)

    # `state` mirrors the human `state=` line, including its `unknown`
    # placeholder; `result_state` is null when there is no result file at all,
    # so a consumer can tell "nothing written yet" from "unusable state".
    printf '{\n'
    printf '  "name": %s,\n' "$(json_str "$name")"
    printf '  "branch": %s,\n' "$(json_str "$branch")"
    printf '  "worktree": %s,\n' "$(json_str "$wt")"
    printf '  "session": %s,\n' "$(json_str "$session")"
    printf '  "state": %s,\n' "$(json_str "$state")"
    printf '  "result_state": %s,\n' "$(json_nullable_str "$rstate")"
    printf '  "result_pr": %s,\n' "$(json_nullable_str "$result_pr")"
    printf '  "result_commit": %s,\n' "$(json_nullable_str "$result_commit")"
    printf '  "result_tests": %s,\n' "$(json_nullable_str "$result_tests")"
    printf '  "running": %s,\n' "$([ "$running" = 1 ] && printf true || printf false)"
    printf '  "input": %s,\n' "$(json_str "$mode")"
    printf '  "session_state": %s,\n' "$(json_str "$sstate")"
    printf '  "turn_state": %s,\n' "$(json_nullable_str "$tstate")"
    printf '  "turn_outcome": %s,\n' "$(json_nullable_str "$tout")"
    printf '  "idle_seconds": %s,\n' "$(json_nullable_num "$idle")"
    printf '  "watcher": %s,\n' "$(json_nullable_str "$watcher")"
    printf '  "wake_lock": %s,\n' "$(json_nullable_str "$wake_lock")"
    printf '  "hours": {\n'
    printf '    "value": %s,\n' "$(json_nullable_str "$HOURS_VALUE")"
    printf '    "age_seconds": %s,\n' "$(json_nullable_num "$HOURS_AGE")"
    printf '    "source": %s\n' "$(json_nullable_str "$HOURS_SOURCE")"
    printf '  },\n'
    printf '  "commit": %s,\n' "$(json_nullable_str "$last_commit")"
    printf '  "dirty": %s,\n' "$([ "$dirty" = yes ] && printf true || printf false)"
    printf '  "pr": %s,\n' "$pr_json"
    printf '  "evidence": {\n'
    printf '    "source": %s,\n' "$(json_nullable_str "$ev_source")"
    printf '    "rule": %s,\n' "$(json_nullable_str "$ev_rule")"
    printf '    "matched": %s,\n' "$(json_nullable_str "$ev_matched")"
    printf '    "window_lines": %s,\n' "$(json_nullable_num "$ev_lines")"
    printf '    "window_sha256": %s,\n' "$(json_nullable_str "$ev_sha")"
    printf '    "stable_scans": %s\n' "$(json_nullable_num "$ev_scans")"
    printf '  },\n'
    printf '  "pane": %s\n' "$(json_nullable_str "$pane")"
    printf '}\n'
}

list_agents() {
    local wt name branch session tmux running state idle activity now idle_secs
    local orphans="" orphan
    # Sessions with no worktree are not in the table below; name them so they
    # cannot be reaped by gc without ever having been seen.
    while IFS= read -r orphan; do
        [ -n "$orphan" ] || continue
        orphan=${orphan#fb-}
        [ -d "$ROOT/.worktrees/$orphan" ] ||
            orphans="${orphans:+$orphans }$orphan"
    done <<<"$(live_sessions)"

    if [ ! -d "$ROOT/.worktrees" ]; then
        note "no worktrees"
        [ -z "$orphans" ] || note "orphans=$orphans (no worktree; see sessions)"
        return 0
    fi
    tmux=$(tmux_bin 2>/dev/null || true)
    now=$(date +%s)
    printf '%-22s %-30s %-26s %-8s %-10s %s\n' \
        NAME BRANCH SESSION RUNNING STATE IDLE
    for wt in "$ROOT"/.worktrees/*; do
        [ -d "$wt" ] || continue
        name=$(basename "$wt")
        branch=$(worktree_branch "$wt")
        session="fb-$name"
        running=no
        state=unknown
        idle=-
        if [ -n "$tmux" ] && "$tmux" has-session -t "$session" 2>/dev/null; then
            running=yes
            state=$(session_state "$name")
            if ! state_is_terminal "$state"; then
                activity=$(session_activity "$name" 2>/dev/null || true)
                if is_num "$activity"; then
                    idle_secs=$((now - activity))
                    [ "$idle_secs" -ge 0 ] || idle_secs=0
                    idle="${idle_secs}s"
                fi
            fi
        else
            state=$(result_state "$wt")
            [ -n "$state" ] || state=unknown
            [ -z "$(refusal_recorded "$wt")" ] || state=refused
        fi
        printf '%-22s %-30s %-26s %-8s %-10s %s\n' \
            "$name" "$branch" "$session" "$running" "$state" "$idle"
    done

    [ -z "$orphans" ] || note "orphans=$orphans (no worktree; see sessions)"
}

watcher_state() {
    # watcher_state WORKTREE -> pid:N when the recorded autostop is alive,
    # dead when it was recorded but has gone, - when no watcher ever started
    local wt="$1" pid
    pid=$(grep -o 'autostop=pid:[0-9]*' "$wt/.supervisor.log" 2>/dev/null |
        tail -n 1 | cut -d: -f2 || true)
    [ -n "$pid" ] || {
        printf '%s' '-'
        return 0
    }
    if kill -0 "$pid" 2>/dev/null; then
        printf 'pid:%s' "$pid"
    else
        printf 'dead'
    fi
}

live_sessions() {
    # live_sessions -> fb-* session names, one per line, none when tmux is gone
    local tmux
    tmux=$(tmux_bin 2>/dev/null || true)
    [ -n "$tmux" ] || return 0
    "$tmux" list-sessions -F '#{session_name}' 2>/dev/null | grep '^fb-' || true
}

live_session_count() {
    # live_session_count -> number of live fb-* sessions (0 when none)
    local count
    count=$(live_sessions | grep -c . || true)
    printf '%s' "${count:-0}"
}

finished_live() {
    # finished_live NAME [TMUX] -> 0 when the TUI is alive but its run is over.
    # The vendor counts live sessions against the concurrent-session limit, not
    # runs, so a done, blocked or failed session holds a slot that buys nothing.
    # `refused` is not in that set: stop is what clears a refusal, and the pane
    # may still be live under it.
    local name=$1 tmux=${2:-} state
    [ -n "$tmux" ] || tmux=$(tmux_bin 2>/dev/null || true)
    [ -n "$tmux" ] || return 1
    "$tmux" has-session -t "fb-$name" 2>/dev/null || return 1
    state=$(session_state "$name")
    state_is_terminal "$state"
}

finished_live_names() {
    # finished_live_names [TMUX] -> the names of live sessions that hold a
    # vendor slot for nothing, comma-separated, empty when none. That is a
    # session whose run is terminal, plus any session whose worktree is gone:
    # it has no result file left to read, and only a slot to lose. `sessions`
    # counts them and a refused `start` names them, so the next step is `gc`
    # rather than guessing which session to stop.
    local tmux=${1:-} name out=''
    [ -n "$tmux" ] || tmux=$(tmux_bin 2>/dev/null || true)
    [ -n "$tmux" ] || return 0
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        name=${name#fb-}
        if [ -d "$ROOT/.worktrees/$name" ]; then
            finished_live "$name" "$tmux" || continue
        fi
        out="${out:+$out,}$name"
    done <<<"$(live_sessions)"
    printf '%s' "$out"
}

sessions() {
    # sessions -> one table over every fb-* session and every worktree, so a
    # session with no worktree is visible before gc reaps it. --json is a
    # serialization of the same rows: one array of objects, `[]` when empty.
    local no_gh=0 json=0 name wt worktree running state idle activity now idle_secs
    local watcher wake_lock result branch pr prs="" slug="" tmux total=0 live=0 trees=0
    local pane hours
    local finished=no finished_count=0
    local names=() x first=1
    while [ $# -gt 0 ]; do
        case "$1" in
            --json) json=1; shift ;;
            --no-gh) no_gh=1; shift ;;
            -h|--help) usage; exit 0 ;;
            *) die "sessions: unsupported argument: $1" ;;
        esac
    done
    tmux=$(tmux_bin 2>/dev/null || true)
    now=$(date +%s)

    while IFS= read -r name; do
        [ -n "$name" ] || continue
        names+=("$name")
    done <<<"$(live_sessions | sed 's/^fb-//')"

    for wt in "$ROOT"/.worktrees/*; do
        [ -d "$wt" ] || continue
        name=$(basename "$wt")
        for x in ${names[@]+"${names[@]}"}; do
            [ "$x" = "$name" ] && continue 2
        done
        names+=("$name")
    done

    if [ ${#names[@]} -eq 0 ]; then
        if [ "$json" = 1 ]; then
            printf '[]\n'
        else
            note 'no sessions'
        fi
        return 0
    fi
    mapfile -t names < <(printf '%s\n' "${names[@]}" | LC_ALL=C sort)

    # One gh call for every branch, instead of one per row.
    if [ "$no_gh" = 0 ]; then
        slug=$(repo_slug || true)
        if [ -n "$slug" ] && command -v "${GH_BIN:-gh}" >/dev/null 2>&1; then
            prs=$("${GH_BIN:-gh}" pr list -R "$slug" --state open \
                --json headRefName,url --jq '.[] | "\(.headRefName) \(.url)"' \
                2>/dev/null || true)
        fi
    fi

    if [ "$json" = 1 ]; then
        printf '[\n'
    elif [ -n "$prs" ]; then
        printf '%-22s %-9s %-8s %-9s %-9s %-9s %-24s %-40s %s %s\n' \
            NAME STATE IDLE WATCHER WORKTREE RESULT BRANCH PR WAKE HOURS
    else
        printf '%-22s %-9s %-8s %-9s %-9s %-9s %-40s %s %s\n' \
            NAME STATE IDLE WATCHER WORKTREE RESULT BRANCH WAKE HOURS
    fi

    for name in "${names[@]}"; do
        wt="$ROOT/.worktrees/$name"
        total=$((total + 1))
        idle_secs=""
        pr=""
        wake_lock=""
        pane=""
        hours=""
        if [ -d "$wt" ]; then
            worktree=yes
            trees=$((trees + 1))
            branch=$(worktree_branch "$wt")
            result=$(result_state "$wt")
            [ -n "$result" ] || result=-
            watcher=$(watcher_state "$wt")
            wake_lock=$(wake_lock_state "$wt")
        else
            worktree=missing
            branch=-
            result=-
            watcher=-
        fi
        running=no
        idle=-
        finished=no
        if [ -n "$tmux" ] && "$tmux" has-session -t "fb-$name" 2>/dev/null; then
            running=yes
            live=$((live + 1))
            state=$(session_state "$name")
            # A finished run whose TUI is still alive holds a vendor slot. The
            # count is what a refused start points at; `gc` is what frees it.
            if state_is_terminal "$state"; then
                finished=yes
                finished_count=$((finished_count + 1))
            fi
            # A finished run has no idle time, even while its TUI process is
            # still alive: null in JSON, `-` in the table, no idle on the card.
            if ! state_is_terminal "$state"; then
                activity=$(session_activity "$name" 2>/dev/null || true)
                if is_num "$activity"; then
                    idle_secs=$((now - activity))
                    [ "$idle_secs" -ge 0 ] || idle_secs=0
                    idle="${idle_secs}s"
                fi
            fi
            # The live pane is read for an hours line; a row whose session is
            # not running, or whose pane carries none, falls back to the
            # ledger and says how old that reading is (#108).
            pane=$("$tmux" capture-pane -p -t "fb-$name" -S "-$HOURS_WINDOW" 2>/dev/null || true)
        elif [ "$worktree" = yes ]; then
            state=$(result_state "$wt")
            [ -n "$state" ] || state=stopped
            [ -z "$(refusal_recorded "$wt")" ] || state=refused
        else
            state=-
        fi

        if hours_read "fb-$name" "$pane"; then
            if [ "$HOURS_FRESH" = 1 ]; then
                hours=$HOURS_VALUE
            else
                hours="$HOURS_VALUE age=$(hours_age_label "$HOURS_AGE")"
            fi
        else
            hours=-
        fi

        if [ -n "$prs" ] && [ "$branch" != '-' ]; then
            pr=$(printf '%s\n' "$prs" |
                awk -v b="$branch" '$1 == b { print $2; exit }')
        fi

        if [ "$json" = 1 ]; then
            [ "$first" = 1 ] || printf ',\n'
            first=0
            printf '  {\n'
            printf '    "name": %s,\n' "$(json_str "$name")"
            printf '    "state": %s,\n' "$(json_nullable_str "$state")"
            printf '    "idle_seconds": %s,\n' "$(json_nullable_num "$idle_secs")"
            if [ "$finished" = yes ]; then
                printf '    "finished": true,\n'
            else
                printf '    "finished": false,\n'
            fi
            printf '    "watcher": %s,\n' "$(json_nullable_str "$watcher")"
            printf '    "wake_lock": %s,\n' "$(json_nullable_str "$wake_lock")"
            printf '    "worktree": %s,\n' "$(json_str "$worktree")"
            printf '    "result": %s,\n' "$(json_nullable_str "$result")"
            printf '    "branch": %s,\n' "$(json_nullable_str "$branch")"
            printf '    "pr": %s,\n' "$(json_nullable_str "$pr")"
            printf '    "hours": {\n'
            printf '      "value": %s,\n' "$(json_nullable_str "$HOURS_VALUE")"
            printf '      "age_seconds": %s,\n' "$(json_nullable_num "$HOURS_AGE")"
            printf '      "source": %s\n' "$(json_nullable_str "$HOURS_SOURCE")"
            printf '    }\n'
            printf '  }'
        elif [ -n "$prs" ] && [ "$branch" != '-' ]; then
            [ -n "$pr" ] || pr=-
            printf '%-22s %-9s %-8s %-9s %-9s %-9s %-24s %-40s %s %s\n' \
                "$name" "$state" "$idle" "$watcher" "$worktree" "$result" \
                "$branch" "$pr" "${wake_lock:--}" "$hours"
        else
            printf '%-22s %-9s %-8s %-9s %-9s %-9s %-40s %s %s\n' \
                "$name" "$state" "$idle" "$watcher" "$worktree" "$result" \
                "$branch" "${wake_lock:--}" "$hours"
        fi
    done

    if [ "$json" = 1 ]; then
        printf '\n]\n'
    else
        printf 'sessions=%s running=%s worktrees=%s orphans=%s finished=%s\n' \
            "$total" "$live" "$trees" "$((total - trees))" "$finished_count"
    fi
}

hours() {
    # hours [NAME] [--json] -> the remaining hour budget, read from a live
    # pane. It is an observation with an age, never an estimate: the welcome
    # panel's `N/M hours remaining` wins over the footer fraction next to the
    # model, and a pane that shows neither (or no live session at all) is
    # unknown with exit 2.
    local name="" json=0 tmux="" session="" pane="" value="" source='' age='' agedisp='-'
    while [ $# -gt 0 ]; do
        case "$1" in
            --json) json=1; shift ;;
            -h|--help) usage; exit 0 ;;
            -*) die "hours: unsupported argument: $1" ;;
            *)
                [ -z "$name" ] || die "hours: at most one NAME"
                name=$1; shift
                ;;
        esac
    done
    if [ -n "$name" ]; then
        valid_name "$name" || die "hours: invalid name"
        session="fb-$name"
    fi
    tmux=$(tmux_bin 2>/dev/null || true)
    [ -n "$session" ] || session=$(live_sessions | head -n 1)

    if [ -n "$tmux" ] && [ -n "$session" ] &&
        "$tmux" has-session -t "$session" 2>/dev/null; then
        pane=$("$tmux" capture-pane -p -t "$session" -S "-$REFUSAL_WINDOW" 2>/dev/null || true)
        value=$(hours_panel "$pane")
        if [ -n "$value" ]; then
            source=panel
        else
            value=$(hours_footer "$pane")
            [ -z "$value" ] || source=footer
        fi
        # The age is the time since tmux last saw activity, the last moment
        # the pane could have changed: the reading is at least that old. A
        # session that cannot report its activity has no age, not a zero.
        age=$(idle_seconds "${session#fb-}" 2>/dev/null || true)
        [ -z "$age" ] || agedisp="${age}s"
        if [ -z "$value" ]; then
            if [ "$json" = 1 ]; then
                printf '{"hours":null,"session":%s,"age":%s,"source":null}\n' \
                    "$(json_nullable_str "$session")" "$(json_nullable_num "$age")"
            else
                note "hours=unknown session=$session age=$agedisp source=none"
            fi
            exit 2
        fi
        if [ "$json" = 1 ]; then
            printf '{"hours":%s,"session":%s,"age":%s,"source":%s}\n' \
                "$(json_str "$value")" "$(json_str "$session")" \
                "$(json_nullable_num "$age")" "$(json_str "$source")"
        else
            note "hours=$value session=$session age=$agedisp source=$source"
        fi
        return 0
    fi

    # No live pane: the tool cannot invent a number it has not read.
    if [ "$json" = 1 ]; then
        printf '{"hours":null,"session":null,"age":null,"source":null}\n'
    else
        note 'hours=unknown'
    fi
    exit 2
}

models() {
    # models [NAME] [--json] -> the models the client's /model picker offers,
    # read from a live session. The client has no catalog command and no
    # --model flag, so the picker is the catalog: it is opened with /model,
    # walked to the end of the list (the frame draws one page and the arrow
    # keys scroll the rest into view), and closed with Escape, which leaves
    # the session as it was. Nothing is submitted, so the walk spends no
    # hours. Only a resting session is touched: a turn in flight or a refused
    # session gets no keys at all.
    local name="" json=0 tmux="" session="" wt="" pane="" opened=0
    local listed="" rows="" n pr sel step=0 count=0 first=1
    while [ $# -gt 0 ]; do
        case "$1" in
            --json) json=1; shift ;;
            -h|--help) usage; exit 0 ;;
            -*) die "models: unsupported argument: $1" ;;
            *)
                [ -z "$name" ] || die "models: at most one NAME"
                name=$1; shift
                ;;
        esac
    done
    tmux=$(tmux_bin 2>/dev/null || true)
    if [ -n "$name" ]; then
        valid_name "$name" || die "models: invalid name"
        session="fb-$name"
    fi
    if [ -z "$session" ]; then
        session=$(live_sessions | head -n 1)
    fi
    if [ -z "$session" ]; then
        note 'model=none'
        die "models: no live fb-* session to read the picker from; start one first"
    fi
    [ -n "$tmux" ] || die 'models: tmux not found; the picker can only be read from a live pane'
    "$tmux" has-session -t "$session" 2>/dev/null ||
        die "models: session $session is not live"
    [ -n "$name" ] || name=${session#fb-}
    wt="$ROOT/.worktrees/$name"
    pane=$("$tmux" capture-pane -p -t "$session" 2>/dev/null || true)
    if picker_frame "$pane"; then
        opened=0
    else
        if [ -n "$(refusal_recorded "$wt")" ]; then
            die "models: $session is refused; stop it first (no keys were sent)"
        fi
        if printf '%s\n' "$pane" | grep -qiE "$BUSY_RE"; then
            die "models: $session is working; the picker is only read from a resting session (no keys were sent)"
        fi
        "$tmux" send-keys -t "$session" -l '/model' 2>/dev/null || true
        sleep "$MODEL_PICKER_POLL"
        "$tmux" send-keys -t "$session" C-m 2>/dev/null || true
        if ! picker_wait "$tmux" "$session" "$MODEL_PICKER_TIMEOUT" "$MODEL_PICKER_POLL"; then
            die "models: /model did not open the picker in $session after ${PICKER_ELAPSED}s"
        fi
        opened=1
        pane=$MODEL_FRAME
    fi
    # One page at a time: collect what the frame draws, press Down, repeat
    # until the marker stops moving. That is the end of the list; the walk is
    # what makes the entries below the fold reachable.
    while :; do
        while IFS=$'\t' read -r _ n pr; do
            [ -n "$n" ] || continue
            printf '%s\n' "$listed" | grep -qxF -- "$n" && continue
            listed="${listed:+$listed$'\n'}$n"
            rows="${rows:+$rows$'\n'}$n"$'\t'"$pr"
            count=$((count + 1))
        done <<<"$(picker_entries "$pane")"
        [ "$step" -lt "$MODEL_PICKER_STEPS" ] || break
        sel=$(picker_selected "$pane")
        "$tmux" send-keys -t "$session" Down 2>/dev/null || true
        step=$((step + 1))
        sleep "$MODEL_PICKER_POLL"
        pane=$("$tmux" capture-pane -p -t "$session" 2>/dev/null || true)
        picker_frame "$pane" || break
        [ "$(picker_selected "$pane")" != "$sel" ] || break
    done
    # A picker this command opened is closed again, so the session is left
    # exactly as it was found; one that was already open is left open.
    if [ "$opened" = 1 ]; then
        "$tmux" send-keys -t "$session" Escape 2>/dev/null || true
    fi
    if [ "$json" = 1 ]; then
        printf '{\n  "session": %s,\n  "count": %s,\n  "models": [\n' \
            "$(json_str "$session")" "$count"
        while IFS=$'\t' read -r n pr; do
            [ -n "$n" ] || continue
            [ "$first" = 1 ] || printf ',\n'
            first=0
            printf '    {"name": %s, "hours": %s, "price": %s}' \
                "$(json_str "$n")" "$(json_str "$(model_hours_cost "$pr")")" \
                "$(json_str "$pr")"
        done <<<"$rows"
        printf '\n  ]\n}\n'
        return 0
    fi
    while IFS=$'\t' read -r n pr; do
        [ -n "$n" ] || continue
        printf 'model=%s hours=%s\n' "$n" "$(model_hours_cost "$pr")"
    done <<<"$rows"
    printf 'models=%s session=%s\n' "$count" "$session"
}

