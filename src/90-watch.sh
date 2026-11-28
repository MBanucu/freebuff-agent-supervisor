# ---- watch, autostop, notify, reap and gc ----
# The lifecycle: follow a run, stop what has finished or gone quiet, and record
# the evidence the review needs. The state monitor at the end is the same
# follow, across every live session at once, into one ledger.
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

monitor_field() {
    # monitor_field LINE KEY -> the value of KEY in one ledger line. The file
    # ships no JSON parser, so this reads back only the shape its own writer
    # produces: a quoted string or a bare number, each key once per line, and
    # values that need no escape because every field is a word or a digit.
    local line="$1" key="$2"
    printf '%s' "$line" | awk -v key="$key" '
        {
            pat = "\"" key "\":"
            at = index($0, pat)
            if (!at) exit
            v = substr($0, at + length(pat))
            if (substr(v, 1, 1) == "\"") {
                v = substr(v, 2)
                q = index(v, "\"")
                if (q) v = substr(v, 1, q - 1)
            } else {
                sub(/[^0-9].*/, "", v)
            }
            printf "%s", v
        }
    '
}

monitor_history() {
    # monitor_history LEDGER NAME NOW WINDOW -> what one scan needs from a
    # session's recorded past, as key=value lines: `prev`, the state it was
    # last seen in; `run_start`, when the state it holds now began (0 when
    # nothing was recorded); `transitions`, the entries that changed state
    # inside the flap window; and `stuck`, yes when this run already carries a
    # stuck flag. The ledger is the monitor's only memory, so a long loop and
    # a cron `--once` see the same history.
    local ledger="$1" name="$2" now="$3" window="$4"
    [ -f "$ledger" ] || return 0
    awk -v name="$name" -v now="$now" -v window="$window" '
        function str(line, key,    pat, v, at) {
            pat = "\"" key "\":\""
            at = index(line, pat)
            if (!at) return ""
            v = substr(line, at + length(pat))
            q = index(v, "\"")
            if (q) v = substr(v, 1, q - 1)
            return v
        }
        function num(line, key,    pat, v, at) {
            pat = "\"" key "\":"
            at = index(line, pat)
            if (!at) return 0
            v = substr(line, at + length(pat))
            sub(/[^0-9].*/, "", v)
            return v + 0
        }
        str($0, "name") == name {
            n++
            ts[n] = num($0, "ts")
            state[n] = str($0, "state")
            prev[n] = str($0, "prev")
            stucksecs[n] = num($0, "stuck_seconds")
            # A record whose state equals its prev is a flag, not a change.
            if (state[n] != prev[n] && ts[n] >= now - window) flaps++
        }
        END {
            if (n == 0) {
                printf "prev=\nrun_start=0\ntransitions=0\nstuck=no\n"
                exit
            }
            last = state[n]
            start = ts[n]
            flagged = 0
            for (i = n; i >= 1 && state[i] == last; i--) {
                if (state[i] == prev[i]) {
                    # A flag entry carries how long the run had lasted when it
                    # was written, so the run clock survives it instead of
                    # restarting at the flag.
                    flagged = 1
                    start = ts[i] - stucksecs[i]
                } else {
                    start = ts[i]
                }
            }
            printf "prev=%s\nrun_start=%s\ntransitions=%s\nstuck=%s\n", \
                last, start, flaps, (flagged ? "yes" : "no")
        }
    ' "$ledger" 2>/dev/null || true
}

monitor_record() {
    # monitor_record TS NAME STATE PREV RULE FINGERPRINT STUCK_SECONDS -> one
    # ledger line, the object #43 names, in a fixed order. It is built whole
    # before it is written, so the append is one short write.
    printf '{"ts":%s,"name":%s,"state":%s,"prev":%s,"rule":%s,"fingerprint":%s,"stuck_seconds":%s}' \
        "$1" "$(json_str "$2")" "$(json_str "$3")" "$(json_str "$4")" \
        "$(json_str "$5")" "$(json_str "$6")" "$7"
}

monitor_print() {
    # monitor_print RECORD FLAG JSON -> the line for one report. With --json it
    # is the ledger object itself, plus `flag` when there is one; otherwise it
    # is the key=value line, which names the extra fields only when they carry
    # news: stuck_seconds for a stuck run, the threshold for a flap.
    local record="$1" flag="${2:-}" json="${3:-0}" out
    if [ "$json" = 1 ]; then
        if [ -n "$flag" ]; then
            record=$(printf '%s' "$record" | sed "s/}\$/,\"flag\":\"$flag\"}/")
        fi
        note "$record"
        return 0
    fi
    out="ts=$(monitor_field "$record" ts) name=$(monitor_field "$record" name) state=$(monitor_field "$record" state) prev=$(monitor_field "$record" prev) rule=$(monitor_field "$record" rule)"
    case "$flag" in
        stuck)
            out+=" flag=stuck stuck_seconds=$(monitor_field "$record" stuck_seconds)"
            ;;
        flapping)
            out+=" flag=flapping transitions=$((MONITOR_FLAP_LIMIT + 1)) window=${MONITOR_FLAP_WINDOW}s"
            ;;
    esac
    note "$out"
}

monitor_append() {
    # monitor_append LEDGER MAX_BYTES LINE -> rotate at the cap, then append
    # LINE once. A single write to a file opened in append mode is atomic for a
    # short record, so two monitors interleave whole lines and never a
    # truncated one. Rotation renames first: a concurrent writer's fd follows
    # the file it opened, so its line lands in one file, never across both.
    local ledger="$1" max="$2" line="$3" size
    if [ -f "$ledger" ]; then
        size=$(wc -c <"$ledger" 2>/dev/null | tr -d ' ' || true)
        is_num "$size" || size=0
        if [ "$size" -ge "$max" ]; then
            mv -f "$ledger" "$ledger.1" 2>/dev/null || true
        fi
    fi
    (umask 077; printf '%s\n' "$line" >>"$ledger") ||
        die "monitor: cannot write ledger: $ledger"
    chmod 600 "$ledger" 2>/dev/null || true
}

monitor_scan() {
    # monitor_scan LEDGER STUCK_AFTER MAX_BYTES FAIL_ON JSON -> one scan of
    # every live session. classify_state reads the pane once per session (and
    # twice only for its own documented unknown rescan; the monitor adds no
    # capture of its own). A transition appends one ledger line, a state held
    # past the deadline appends one stuck flag, and the fourth transition
    # inside the window prints one flapping report. Returns 3 when FAIL_ON is
    # unknown and a session is unclassified, 0 otherwise.
    local ledger="$1" stuck_after="$2" max="$3" fail_on="$4" json="$5"
    local now name state rule fp block history prev run_start transitions
    local was_stuck record stuck flapping unknown=0 rc=0
    now=$(date +%s)

    while IFS= read -r name; do
        [ -n "$name" ] || continue
        # Session names come from tmux, so one is checked before it is used
        # anywhere, as every other reader of one does.
        if ! valid_name "$name"; then
            printf 'monitor: skip invalid session name: fb-%s\n' "$name" >&2
            continue
        fi
        block=$(classify_state "$name" "$REFUSAL_WINDOW" pane)
        state=$(evidence_field "$block" state)
        rule=$(evidence_field "$block" rule)
        fp=$(evidence_field "$block" window_sha256)
        # A verdict from a file has no window to hash, so its fingerprint is
        # its own state and rule: stable while nothing changes, distinct
        # across states.
        [ -n "$fp" ] ||
            fp=$(printf 'state=%s\nrule=%s\n' "$state" "$rule" | sha256_hex)
        [ -n "$state" ] || state=unknown
        [ -n "$rule" ] || rule=no-rule-matched
        [ "$state" != unknown ] || unknown=$((unknown + 1))

        history=$(monitor_history "$ledger" "$name" "$now" "$MONITOR_FLAP_WINDOW")
        prev=$(evidence_field "$history" prev)
        run_start=$(evidence_field "$history" run_start)
        transitions=$(evidence_field "$history" transitions)
        was_stuck=$(evidence_field "$history" stuck)
        is_num "$run_start" || run_start=0
        is_num "$transitions" || transitions=0
        [ -n "$was_stuck" ] || was_stuck=no

        if [ "$state" != "$prev" ]; then
            # Seconds spent in the state that is ending; an empty prev is the
            # first sight of the session and has no earlier clock.
            stuck=0
            if [ -n "$prev" ] && [ "$run_start" -gt 0 ] &&
                [ "$now" -gt "$run_start" ]; then
                stuck=$((now - run_start))
            fi
            record=$(monitor_record "$now" "$name" "$state" "$prev" "$rule" "$fp" "$stuck")
            monitor_append "$ledger" "$max" "$record"
            monitor_print "$record" '' "$json"
            # A flap is reported where it is crossed, so one burst of
            # transitions is one report rather than one per further poll.
            [ $((transitions + 1)) -eq $((MONITOR_FLAP_LIMIT + 1)) ] || continue
            flapping=$(monitor_record "$now" "$name" "$state" "$state" "$rule" "$fp" 0)
            monitor_print "$flapping" flapping "$json"
        elif ! state_is_terminal "$state" && [ "$run_start" -gt 0 ] &&
            [ "$now" -gt $((run_start + stuck_after)) ] &&
            [ "$was_stuck" = no ]; then
            stuck=$((now - run_start))
            record=$(monitor_record "$now" "$name" "$state" "$state" "$rule" "$fp" "$stuck")
            monitor_append "$ledger" "$max" "$record"
            monitor_print "$record" stuck "$json"
        fi
    done <<<"$(live_sessions | sed 's/^fb-//' | LC_ALL=C sort)"

    if [ "$fail_on" = unknown ] && [ "$unknown" -gt 0 ]; then
        rc=3
    fi
    return "$rc"
}

monitor() {
    local interval="$MONITOR_INTERVAL" once=0 stuck_after="$MONITOR_STUCK_AFTER"
    local json=0 ledger='' max="$MONITOR_LEDGER_MAX" fail_on='' rc=0 dir
    while [ $# -gt 0 ]; do
        case "$1" in
            --interval) interval=${2:-}; shift 2 ;;
            --once) once=1; shift ;;
            --stuck-after) stuck_after=${2:-}; shift 2 ;;
            --json) json=1; shift ;;
            --ledger) ledger=${2:-}; shift 2 ;;
            --ledger-max-bytes) max=${2:-}; shift 2 ;;
            --fail-on) fail_on=${2:-}; shift 2 ;;
            -h|--help) usage; exit 0 ;;
            *) die "monitor: unsupported argument: $1" ;;
        esac
    done
    is_duration "$interval" ||
        die "monitor: --interval must be a number greater than zero"
    is_num "$stuck_after" || die "monitor: --stuck-after must be a number"
    is_num "$max" || die "monitor: --ledger-max-bytes must be a number"
    [ "$max" -gt 0 ] ||
        die "monitor: --ledger-max-bytes must be greater than zero"
    case "$fail_on" in
        ''|unknown) ;;
        *) die "monitor: --fail-on must be unknown" ;;
    esac
    [ -n "$ledger" ] || ledger="$ROOT/$STATE_LEDGER"
    dir=$(dirname -- "$ledger")
    [ -d "$dir" ] || die "monitor: ledger directory does not exist: $dir"
    # The ledger is runtime state in the repository root like the other two, so
    # a repo that only ever ran the monitor still cannot commit it.
    ensure_excludes

    while :; do
        rc=0
        monitor_scan "$ledger" "$stuck_after" "$max" "$fail_on" "$json" ||
            rc=$?
        [ "$once" = 0 ] || break
        sleep "$interval"
    done
    return "$rc"
}

