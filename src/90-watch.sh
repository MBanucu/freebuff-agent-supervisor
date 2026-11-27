# ---- watch, autostop, reap and gc ----
# The lifecycle: follow a run, stop what has finished or gone quiet, and record
# the evidence the review needs.
reap() {
    # reap NAME REASON [EXTRA] -> record evidence under .worktrees, then kill
    local name="$1" reason="$2" extra="${3:-}" session="fb-$name"
    local wt="$ROOT/.worktrees/$name" log branch="" tmux pr=unknown slug dirty=no
    local pane=""
    tmux=$(tmux_bin 2>/dev/null || true)
    log="$wt/.supervisor.log"
    if [ ! -d "$wt" ]; then
        log="$ROOT/.worktrees/.orphans.log"
    fi
    mkdir -p "$(dirname "$log")"

    if [ -d "$wt" ]; then
        branch=$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
    fi
    slug=$(repo_slug || true)
    if [ -n "$branch" ] && [ -n "$slug" ] &&
        command -v "${GH_BIN:-gh}" >/dev/null 2>&1; then
        pr=$("${GH_BIN:-gh}" pr list -R "$slug" --head "$branch" --state open \
            --json url --jq '.[0].url // "none"' 2>/dev/null || true)
        [ -n "$pr" ] || pr=unknown
    fi
    if [ -d "$wt" ] && [ -n "$(git -C "$wt" status --short 2>/dev/null || true)" ]; then
        dirty=yes
    fi

    if [ -n "$tmux" ] && "$tmux" has-session -t "$session" 2>/dev/null; then
        pane=$("$tmux" capture-pane -p -t "$session" -S -120 2>/dev/null || true)
    fi

    {
        printf '\n=== %s stop name=%s reason=%s session=%s ===\n' \
            "$(date -u +%FT%TZ)" "$name" "$reason" "$session"
        [ -z "$branch" ] || printf 'branch=%s\n' "$branch"
        printf 'commit=%s\n' "$(git -C "$wt" log -1 --oneline 2>/dev/null || true)"
        printf 'dirty=%s\n' "$dirty"
        printf 'pr=%s\n' "$pr"
        [ -z "$extra" ] || printf '%s\n' "$extra"
        if [ -n "$pane" ]; then
            printf '%s\n' 'pane:'
            printf '%s\n' "$pane"
        fi
    } >>"$log"

    if [ -n "$tmux" ] && "$tmux" has-session -t "$session" 2>/dev/null; then
        "$tmux" kill-session -t "$session"
        note "stopped=$session reason=$reason log=$log"
    else
        note "stopped=no (session already gone) reason=$reason log=$log"
    fi
    # The stop is what ends a refusal; the sentence stays in the log above.
    clear_refusal "$wt"

    local gstate
    case "$reason" in
        done|idle) gstate=done ;;
        blocked) gstate=blocked ;;
        failed) gstate=failed ;;
        *) gstate=stopped ;;
    esac
    gh_state "$wt" "$gstate" "🤖 **subagent $gstate** — reason \`$reason\`${branch:+, branch \`$branch\`}, pr=${pr}, dirty=${dirty}. Evidence: \`${log#"$ROOT"/}\`${extra:+
$extra}"
}

watch_run() {
    # watch_run NAME IDLE_SECONDS POLL TIMEOUT -> 0 done/idle, 1 timeout,
    # 2 missing, 3 blocked, 4 failed. The result file's own state is the
    # contract; a killed watcher's exit is not read as the run's outcome.
    local name="$1" idle_limit="$2" poll="$3" timeout="$4"
    local tmux session start now state last_state="" pane hash last_hash=""
    local idle_since="" elapsed
    tmux=$(tmux_bin) || die "watch: tmux not found"
    session="fb-$name"
    start=$(date +%s)

    while :; do
        now=$(date +%s)
        if [ "$timeout" -gt 0 ] && [ $((now - start)) -ge "$timeout" ]; then
            note "state=timeout elapsed=$((now - start))s"
            return 1
        fi
        state=$(session_state "$name")
        case "$state" in
            done)
                note 'state=done'
                return 0
                ;;
            blocked)
                note 'state=blocked'
                gh_state "$ROOT/.worktrees/$name" blocked \
                    "🤖 **subagent blocked** — session \`fb-$name\` is waiting on input; \`spawn-freebuff-agent status $name\` shows the pane." || true
                return 3
                ;;
            failed)
                note 'state=failed'
                return 4
                ;;
            missing)
                note 'state=missing'
                return 2
                ;;
        esac
        if [ "$state" != "$last_state" ]; then
            note "state=$state"
            last_state=$state
        fi
        if [ "$state" = idle ]; then
            pane=$("$tmux" capture-pane -p -t "$session" 2>/dev/null || true)
            hash=$(printf '%s' "$pane" | cksum | cut -d' ' -f1)
            if [ "$hash" != "$last_hash" ]; then
                last_hash=$hash
                idle_since=$now
            fi
            [ -n "$idle_since" ] || idle_since=$now
            elapsed=$((now - idle_since))
            note "state=idle idle_seconds=$elapsed"
            if [ "$elapsed" -ge "$idle_limit" ]; then
                return 0
            fi
        else
            idle_since=""
            last_hash=""
        fi
        sleep "$poll"
    done
}

watch() {
    local name="" idle=120 poll=5 timeout=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --idle-seconds) idle=${2:-}; shift 2 ;;
            --poll) poll=${2:-}; shift 2 ;;
            --timeout) timeout=${2:-}; shift 2 ;;
            -h|--help) usage; exit 0 ;;
            -*) die "watch: unsupported argument: $1" ;;
            *) name=$1; shift ;;
        esac
    done
    [ -n "$name" ] || die "watch: NAME is required"
    valid_name "$name" || die "watch: invalid name"
    is_num "$idle" || die "watch: --idle-seconds must be a number"
    is_num "$poll" || die "watch: --poll must be a number"
    is_num "$timeout" || die "watch: --timeout must be a number"
    watch_run "$name" "$idle" "$poll" "$timeout"
}

autostop() {
    local name="" idle=120 poll=5 timeout=0 rc=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --idle-seconds) idle=${2:-}; shift 2 ;;
            --poll) poll=${2:-}; shift 2 ;;
            --timeout) timeout=${2:-}; shift 2 ;;
            -h|--help) usage; exit 0 ;;
            -*) die "autostop: unsupported argument: $1" ;;
            *) name=$1; shift ;;
        esac
    done
    [ -n "$name" ] || die "autostop: NAME is required"
    valid_name "$name" || die "autostop: invalid name"
    is_num "$idle" || die "autostop: --idle-seconds must be a number"
    is_num "$poll" || die "autostop: --poll must be a number"
    is_num "$timeout" || die "autostop: --timeout must be a number"

    watch_run "$name" "$idle" "$poll" "$timeout" || rc=$?
    case "$rc" in
        # 0 is done or the idle window; 3 and 4 are the result file's blocked
        # and failed. All three end the run, so the watcher still stops the
        # session; the exit status keeps the outcome distinguishable.
        0|3|4) reap "$name" "$(session_state "$name")" ;;
    esac
    return "$rc"
}

notify() {
    # notify NAME -> the next turn-end event from the client's per-chat log,
    # one line group per call, for a watcher to poll. Each call advances the
    # cursor in the worktree, so a turn fires once; the first call arms at the
    # end of the log, so history is not replayed. It is an earlier signal than
    # .agent-result, not a replacement: done stays the result file's word.
    # Read-only otherwise: nothing is sent, stopped or written outside the
    # cursor.
    local name=""
    while [ $# -gt 0 ]; do
        case "$1" in
            -h|--help) usage; exit 0 ;;
            -*) die "notify: unsupported argument: $1" ;;
            *)
                [ -z "$name" ] || die "notify: at most one NAME"
                name=$1; shift
                ;;
        esac
    done
    [ -n "$name" ] || die "notify: NAME is required"
    valid_name "$name" || die "notify: invalid name"
    [ -d "$ROOT/.worktrees/$name" ] ||
        die "notify: no worktree at $ROOT/.worktrees/$name"
    turn_log_poll "$name"
}

gc() {
    # Worktree removal is never automatic: --prune-worktrees only prints the
    # cleanup commands. A refused launch is never offered for pruning, because
    # its branch was never pushed and its worktree may hold the only copy of
    # the agent's edits. A session whose worktree is already gone has nothing
    # left to review, so plain gc stops it instead of leaving the vendor slot
    # held behind --all.
    local idle_hours=12 dry=0 prune=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --idle-hours) idle_hours=${2:-}; shift 2 ;;
            --dry-run) dry=1; shift ;;
            --prune-worktrees) prune=1; shift ;;
            --all) shift ;;  # accepted for compatibility; orphans are default
            -h|--help) usage; exit 0 ;;
            *) die "gc: unsupported argument: $1" ;;
        esac
    done
    is_num "$idle_hours" || die "gc: --idle-hours must be a number"

    local tmux now wt name session state idle_secs branch planned
    local names=() orphans=() listed
    tmux=$(tmux_bin) || die "gc: tmux not found"
    now=$(date +%s)

    for wt in "$ROOT"/.worktrees/*; do
        [ -d "$wt" ] || continue
        names+=("$(basename "$wt")")
    done
    listed=$("$tmux" list-sessions -F '#{session_name}' 2>/dev/null || true)
    while IFS= read -r session; do
        case "$session" in
            fb-*)
                name=${session#fb-}
                [ -d "$ROOT/.worktrees/$name" ] || orphans+=("$name")
                ;;
        esac
    done <<<"$listed"

    for name in ${names[@]+"${names[@]}"}; do
        planned=0
        state=$(session_state "$name")
        case "$state" in
            missing)
                continue
                ;;
            done|blocked|failed)
                # All three are a finished agent: blocked and failed still stop
                # the session, and the reason names the result state.
                planned=1
                if [ "$dry" = 1 ]; then
                    note "would-stop name=$name reason=$state"
                else
                    note "stop name=$name reason=$state"
                    reap "$name" "$state"
                fi
                ;;
            refused)
                # The stop is fine (the TUI is dead weight), but the worktree
                # is the evidence: never offer to prune it.
                planned=1
                if [ "$dry" = 1 ]; then
                    note "would-stop name=$name reason=refused"
                else
                    note "stop name=$name reason=refused"
                    reap "$name" refused
                fi
                ;;
            idle)
                idle_secs=$(idle_seconds "$name" 2>/dev/null || true)
                is_num "$idle_secs" || idle_secs=0
                if [ "$idle_secs" -ge $((idle_hours * 3600)) ]; then
                    planned=1
                    if [ "$dry" = 1 ]; then
                        note "would-stop name=$name reason=idle idle_seconds=$idle_secs"
                    else
                        note "stop name=$name reason=idle"
                        reap "$name" idle
                    fi
                else
                    note "skip name=$name reason=idle idle_seconds=$idle_secs"
                fi
                ;;
            unknown)
                # No rule matched, so nothing is known about this pane. Skipping
                # it is the same safe choice as a busy pane: gc never reaps a
                # session it cannot read.
                note "skip name=$name reason=unknown"
                ;;
            *)
                note "skip name=$name reason=busy"
                ;;
        esac
        if [ "$prune" = 1 ] && [ "$planned" = 1 ] && [ "$state" != refused ]; then
            branch=$(git -C "$ROOT/.worktrees/$name" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
            [ -z "$branch" ] || {
                if [ "$dry" = 1 ]; then
                    note "would-prune name=$name cleanup=git worktree remove .worktrees/$name && git branch -d $branch"
                else
                    note "cleanup=git worktree remove .worktrees/$name && git branch -d $branch"
                fi
            }
        fi
    done

    # No worktree means no result file and no branch to review, so the session
    # only holds a vendor slot. Plain gc stops it; --all is no longer needed.
    for name in ${orphans[@]+"${orphans[@]}"}; do
        if [ "$dry" = 1 ]; then
            note "would-stop name=$name reason=orphan"
        else
            note "stop name=$name reason=orphan"
            reap "$name" orphan
        fi
    done
}

