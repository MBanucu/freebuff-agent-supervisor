# ---- state classification and evidence ----
# The pane rules, the evidence block they produce, and the read-only activity
# clock that says how long a session has been quiet.
sha256_hex() {
    # sha256_hex -> a hex digest of stdin, from the first tool present. Only
    # stability matters (the same window must hash the same twice), so cksum
    # is a last resort on a machine with none of the hash tools.
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 | cut -d' ' -f1
    elif command -v openssl >/dev/null 2>&1; then
        openssl dgst -sha256 | sed 's/^.*= //'
    else
        cksum | cut -d' ' -f1
    fi
}

normalise_window() {
    # normalise_window (stdin) -> text a repaint cannot change: no ANSI, no
    # padding, no clocks. Box-drawing rules are dropped because a redraw can
    # reflow them; their content lines stay. Two captures of one unclassified
    # pane hash the same even when the spacing or the elapsed time differs.
    local LC_ALL=C
    sed -E \
        -e $'s/\x1b\\][^\x07]*\x07//g' \
        -e $'s/\x1b\\[[0-9;?]*[A-Za-z]//g' \
        -e 's/\r$//' \
        -e 's/[[:space:]]+/ /g' \
        -e 's/^ //' -e 's/ $//' \
        -e 's/[0-9]+(\.[0-9]+)?(ms|s|m|h)([^0-9A-Za-z]|$)/<time>\3/g' \
        -e 's/(^|[^0-9])[0-9][0-9]?:[0-9][0-9](:[0-9][0-9])?/\1<time>/g' \
        | sed -E '/^[─━═╭╮╰╯│┃├┤┬┴┼╔╗╚╝║╠╣╦╩╬ ]*$/d'
}

first_match() {
    # first_match REGEX TEXT -> the first matching line, trimmed; empty on none
    local line
    line=$(printf '%s\n' "$2" | grep -m1 -iE -- "$1" 2>/dev/null || true)
    line=${line%$'\r'}
    line=$(printf '%s' "$line" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
    printf '%s' "$line"
}

evidence_field() {
    # evidence_field BLOCK KEY -> the first KEY= value in an evidence block
    local block="$1" key="$2" line
    while IFS= read -r line; do
        case "$line" in
            "$key"=*) printf '%s' "${line#"$key"=}"; return 0 ;;
        esac
    done <<<"$block"
}

# classify_chrome fills these, so a rescan can reuse one rule table.
PANE_STATE=''
PANE_RULE=''
PANE_MATCHED=''
PANE_CHECKS=''

classify_chrome() {
    # classify_chrome PANE CHROME -> sets PANE_STATE (empty when nothing
    # matched), PANE_RULE, PANE_MATCHED and the checks that were run. The
    # order is the tool's existing precedence; only the terminal fallback
    # changed.
    local pane="$1" chrome="$2" matched
    PANE_STATE=''
    PANE_RULE=''
    PANE_MATCHED=''
    PANE_CHECKS=''

    # The refusal can be the turn text above the resting prompt, not just the
    # 12-line chrome window, so scan enough scrollback to see the answer.
    matched=$(first_match "$REFUSED_RE" "$pane")
    PANE_CHECKS+="check: refusal-prose: $([ -n "$matched" ] && printf yes || printf no)"
    if [ -n "$matched" ]; then
        PANE_STATE=refused
        PANE_RULE=refusal-prose
        PANE_MATCHED=$matched
        return 0
    fi

    matched=$(first_match "$BUSY_RE" "$chrome")
    PANE_CHECKS+=$'\n'"check: busy-marker pattern=\"$BUSY_RE\": $([ -n "$matched" ] && printf yes || printf no)"
    if [ -n "$matched" ]; then
        PANE_STATE=working
        PANE_RULE=busy-marker
        PANE_MATCHED=$matched
        return 0
    fi

    # The resting prompt means no turn is running, so it outranks the
    # protected strings: the startup `Can't reach Freebuff` banner lands in the
    # same 12-line window and would otherwise pin a finished session at
    # `working` forever, which is the leak this tool exists to prevent.
    matched=$(first_match 'Enter a coding task' "$chrome")
    PANE_CHECKS+=$'\n'"check: resting-prompt pattern=\"Enter a coding task\": $([ -n "$matched" ] && printf yes || printf no)"
    if [ -n "$matched" ]; then
        PANE_STATE=idle
        PANE_RULE=resting-prompt
        PANE_MATCHED=$matched
        return 0
    fi

    matched=$(first_match "$PROTECTED_RE" "$chrome")
    PANE_CHECKS+=$'\n'"check: protected-window pattern=\"$PROTECTED_RE\": $([ -n "$matched" ] && printf yes || printf no)"
    if [ -n "$matched" ]; then
        PANE_STATE=working
        PANE_RULE=protected-window
        PANE_MATCHED=$matched
        return 0
    fi
}

freebuff_config_dir() {
    # freebuff_config_dir -> the client's config root. FREEBUFF_CONFIG_DIR
    # wins, as it does in the client; otherwise the client's own default.
    printf '%s' "${FREEBUFF_CONFIG_DIR:-${HOME:-}/.config/manicode}"
}

turn_log_path() {
    # turn_log_path NAME -> the newest chat's log.jsonl, or nothing. The
    # client names the project directory basename(cwd), so the worktree name
    # is the project name; worktree names here are unique, which is what keeps
    # two checkouts from sharing one project directory. The newest chat is the
    # one whose run-state.json or chat-messages.json was written last, because
    # the client rewrites those at every message boundary.
    local name="$1" chats newest
    chats="$(freebuff_config_dir)/projects/$(basename -- "$ROOT/.worktrees/$name")/chats"
    [ -d "$chats" ] || return 0
    newest=$(ls -1t "$chats"/*/run-state.json "$chats"/*/chat-messages.json \
        2>/dev/null | head -n 1 || true)
    if [ -n "$newest" ]; then
        newest=$(dirname -- "$newest")
    else
        newest=$(ls -1dt "$chats"/*/ 2>/dev/null | head -n 1 || true)
        newest=${newest%/}
    fi
    [ -n "$newest" ] || return 0
    [ -f "$newest/log.jsonl" ] || return 0
    printf '%s' "$newest/log.jsonl"
}

turn_log_read() {
    # turn_log_read LOG -> tab-separated "start end outcome startline endline".
    # A turn starts at `Sending message with sdk run config` and ends at
    # `Main prompt finished`, whose data.outputType is the outcome. Only a
    # complete JSON line counts, so a half-written final line is ignored and
    # picked up on the next read instead of being guessed at.
    awk '
        /\}[[:space:]]*$/ && index($0, "Main prompt finished") {
            end = NR; endline = $0
            outcome = $0
            sub(/.*"outputType"[[:space:]]*:[[:space:]]*"/, "", outcome)
            if (outcome != $0) { sub(/".*/, "", outcome) } else { outcome = "" }
        }
        /\}[[:space:]]*$/ && index($0, "Sending message with sdk run config") {
            start = NR; startline = $0
        }
        END {
            printf "%d\t%d\t%s\t%s\t%s\n", start + 0, end + 0, outcome, startline, endline
        }
    ' "$1" 2>/dev/null || true
}

turn_log_evidence() {
    # turn_log_evidence NAME [CHECKS] -> the evidence block from the turn log.
    # `turn_state` is the start/end pair's verdict and `turn_outcome` the end's
    # outputType. `state` maps a finished turn to `idle`, because the pane
    # would rest at its prompt; `done` stays the result file's word, so the
    # log cannot claim a run succeeded. A missing chat directory is
    # `unknown`/`no-turn-log`, never an error.
    local name="$1" checks="${2:-}"
    local chats log parsed start end outcome startline endline
    local state rule matched mapped log_checks
    chats="$(freebuff_config_dir)/projects/$(basename -- "$ROOT/.worktrees/$name")/chats"
    log=$(turn_log_path "$name")
    if [ -z "$log" ]; then
        log_checks="check: turn-log ($chats): no"
        [ -z "$checks" ] || log_checks="$checks"$'\n'"$log_checks"
        printf 'state=unknown\nsource=log\nrule=no-turn-log\nmatched=\nturn_state=unknown\nturn_outcome=\nturn_log=no\nwindow_lines=0\nwindow_sha256=\nstable_scans=0\n%s\npane_begin\npane_end\n' \
            "$log_checks"
        return 0
    fi
    parsed=$(turn_log_read "$log")
    IFS=$'\t' read -r start end outcome startline endline <<<"$parsed" || true
    is_num "$start" || start=0
    is_num "$end" || end=0
    if [ "$start" -eq 0 ] && [ "$end" -eq 0 ]; then
        state=unknown
        rule=no-turn-events
        matched=''
    elif [ "$start" -gt "$end" ]; then
        state=working
        rule=turn-started
        matched=$startline
        outcome=''
    elif [ "$outcome" = error ]; then
        state=failed
        rule=turn-failed
        matched=$endline
    else
        state=finished
        rule=turn-finished
        matched=$endline
    fi
    mapped=$state
    [ "$state" != finished ] || mapped=idle
    log_checks="check: turn-log ($log): yes"
    log_checks+=$'\n'"check: turn-start (line $start): $([ "$start" -gt 0 ] && printf yes || printf no)"
    log_checks+=$'\n'"check: turn-end (line $end): $([ "$end" -gt 0 ] && printf yes || printf no)"
    [ -z "$checks" ] || log_checks="$checks"$'\n'"$log_checks"
    printf 'state=%s\nsource=log\nrule=%s\nmatched=%s\nturn_state=%s\nturn_outcome=%s\nturn_log=yes\nwindow_lines=0\nwindow_sha256=\nstable_scans=0\n%s\npane_begin\npane_end\n' \
        "$mapped" "$rule" "${matched:0:200}" "$state" "$outcome" "$log_checks"
}

turn_log_cursor() {
    # turn_log_cursor NAME -> the per-worktree cursor for the turn log. It
    # lives inside .worktrees/, which is ignored and removed with the run
    # evidence, so it is never committed and never outlives its worktree.
    printf '%s' "$ROOT/.worktrees/$1/.turn-log-cursor"
}

turn_log_poll() {
    # turn_log_poll NAME -> one turn-end event since the saved cursor, as
    # key=value lines, and advances that cursor. A turn is a complete
    # `Sending message with sdk run config` line followed by a complete
    # `Main prompt finished` line; outputType picks finished (lastMessage) or
    # failed (error), so the two outcomes stay distinct (#74).
    #
    # The first poll of a log arms the cursor at its current end instead of
    # replaying turns already on disk, so a watcher started mid-session does
    # not report history as news. Only complete lines are read: a half-written
    # final line stays in the file and is picked up once the writer finishes
    # it. There is no chat directory or no log.jsonl -> event=none with
    # reason=no-turn-log and exit 2, never a stack trace and never a hang.
    local name="$1" wt chats log cursor saved_log saved_offset size offset=0
    local ends_nl=1 line i start_idx=-1 end_idx=-1 outcome='' state=''
    local advance=0
    local -a raw=()
    local LC_ALL=C
    wt="$ROOT/.worktrees/$name"
    chats="$(freebuff_config_dir)/projects/$(basename -- "$wt")/chats"
    log=$(turn_log_path "$name")
    if [ -z "$log" ]; then
        printf 'event=none\nreason=no-turn-log\nchats=%s\n' "$chats"
        return 2
    fi
    cursor=$(turn_log_cursor "$name")
    size=$(wc -c <"$log" 2>/dev/null | tr -d ' ' || true)
    is_num "$size" || size=0

    if [ -f "$cursor" ]; then
        saved_log=$(sed -n 's/^log=//p' "$cursor" | tail -n 1)
        saved_offset=$(sed -n 's/^offset=//p' "$cursor" | tail -n 1)
        # A cursor from another chat directory, or one older than the file,
        # says nothing about this log: arm again rather than guess.
        if [ "$saved_log" = "$log" ] && is_num "$saved_offset" &&
            [ "$saved_offset" -le "$size" ]; then
            offset=$saved_offset
        else
            offset=-1
        fi
    else
        offset=-1
    fi
    if [ "$offset" -lt 0 ]; then
        printf 'log=%s\noffset=%s\n' "$log" "$size" >"$cursor"
        printf 'event=none\nreason=armed\nlog=%s\noffset=%s\n' "$log" "$size"
        return 0
    fi

    if [ "$size" -gt "$offset" ]; then
        # wc -l on the last byte says whether the writer finished the line.
        [ "$(tail -c 1 "$log" | wc -l)" -eq 1 ] || ends_nl=0
        # `read` stops before a final line the writer has not terminated, so
        # a half-written record never enters raw at all.
        while IFS= read -r line; do
            raw+=("$line")
        done < <(tail -c +"$((offset + 1))" "$log" 2>/dev/null)
    fi

    for i in "${!raw[@]}"; do
        line=${raw[$i]}
        if [ "$start_idx" -lt 0 ]; then
            case "$line" in
                *"Sending message with sdk run config"*)
                    if [[ $line == *'}' ]]; then
                        start_idx=$i
                    fi
                    ;;
            esac
            continue
        fi
        case "$line" in
            *"Main prompt finished"*)
                [[ $line == *'}' ]] || continue
                end_idx=$i
                if [[ $line =~ \"outputType\"[[:space:]]*:[[:space:]]*\"([^\"]*)\" ]]; then
                    outcome=${BASH_REMATCH[1]}
                fi
                break
                ;;
        esac
    done

    # Consume through the end of the fired turn. An unfinished turn keeps its
    # start line for the next poll; lines before any start are noise to drop.
    if [ "$end_idx" -ge 0 ]; then
        for ((i = 0; i <= end_idx; i++)); do
            advance=$((advance + ${#raw[$i]} + 1))
        done
    elif [ "$start_idx" -gt 0 ]; then
        for ((i = 0; i < start_idx; i++)); do
            advance=$((advance + ${#raw[$i]} + 1))
        done
    elif [ "$start_idx" -lt 0 ]; then
        for ((i = 0; i < ${#raw[@]}; i++)); do
            advance=$((advance + ${#raw[$i]} + 1))
        done
    fi
    if [ "$advance" -gt 0 ]; then
        printf 'log=%s\noffset=%s\n' "$log" "$((offset + advance))" >"$cursor"
    fi

    if [ "$end_idx" -ge 0 ]; then
        case "$outcome" in
            error) state=failed ;;
            lastMessage) state=finished ;;
            *) state=unknown ;;
        esac
        printf 'event=turn-end\nturn_state=%s\nturn_outcome=%s\nlog=%s\n' \
            "$state" "$outcome" "$log"
        return 0
    fi
    if [ "$start_idx" -ge 0 ]; then
        printf 'event=none\nreason=turn-running\nlog=%s\n' "$log"
        return 0
    fi
    if [ "$ends_nl" = 0 ]; then
        printf 'event=none\nreason=partial-line\nlog=%s\n' "$log"
        return 0
    fi
    printf 'event=none\nreason=no-new-turn\nlog=%s\n' "$log"
    return 0
}

concord_file() {
    # concord_file WORKTREE -> the generated work-state export
    printf '%s/%s' "$1" "$CONCORD_FILE"
}

concord_validate() {
    # concord_validate FILE -> 0 when FILE has the export's outer shape.
    # The tool ships no JSON parser, so this is the strongest check that needs
    # no runtime: a brace-delimited object with a tasks array. A file that
    # fails it is corrupt, never "no tasks", so the caller can name the fault.
    local file=$1 first last
    [ -f "$file" ] && [ -s "$file" ] || return 1
    first=$(grep -m1 -v '^[[:space:]]*$' "$file" 2>/dev/null |
        sed -E 's/^[[:space:]]+//' || true)
    [ "${first:0:1}" = '{' ] || return 1
    last=$(grep -v '^[[:space:]]*$' "$file" 2>/dev/null | tail -n 1 |
        sed -E 's/[[:space:]]+$//' || true)
    [ "${last: -1}" = '}' ] || return 1
    grep -qE '"tasks"[[:space:]]*:[[:space:]]*\[' "$file" || return 1
    return 0
}

concord_task_record() {
    # concord_task_record FILE BRANCH -> status, task_id, branch and
    # updated_at of the task this worktree owns, tab-separated. Concord's
    # workspace is shared by the main checkout and every linked worktree, so
    # the worktree's branch selects its task; with no match a lone task is
    # unambiguous, several are not, and `no-task` lets auto fall back.
    local file=$1 branch=$2
    awk -v branch="$branch" '
        function value(line, key,    pat, v) {
            pat = "\"" key "\"[[:space:]]*:[[:space:]]*\""
            if (!match(line, pat)) return ""
            v = substr(line, RSTART + RLENGTH)
            sub(/".*/, "", v)
            return v
        }
        function number(line, key,    pat, v) {
            pat = "\"" key "\"[[:space:]]*:[[:space:]]*"
            if (!match(line, pat)) return 0
            v = substr(line, RSTART + RLENGTH)
            sub(/[^0-9].*/, "", v)
            return v + 0
        }
        /"tasks"[[:space:]]*:[[:space:]]*\[/ { in_tasks = 1; next }
        in_tasks && /^[[:space:]]*\][[:space:]]*,?[[:space:]]*$/ {
            in_tasks = 0; next
        }
        in_tasks && !in_rec && /^[[:space:]]*\{[[:space:]]*$/ {
            in_rec = 1; status = ""; id = ""; br = ""; updated = ""; version = 0
            next
        }
        in_tasks && in_rec && /^[[:space:]]*\},?[[:space:]]*$/ {
            n++
            t_status[n] = status; t_id[n] = id; t_branch[n] = br
            t_updated[n] = updated; t_version[n] = version
            in_rec = 0
            next
        }
        in_tasks && in_rec {
            key = $0
            sub(/^[[:space:]]*"/, "", key)
            sub(/".*/, "", key)
            if (key == "status") status = value($0, "status")
            else if (key == "task_id") id = value($0, "task_id")
            else if (key == "branch") br = value($0, "branch")
            else if (key == "updated_at") updated = value($0, "updated_at")
            else if (key == "version") version = number($0, "version")
        }
        END {
            best = 0
            for (i = 1; i <= n; i++) {
                if (branch != "" && t_branch[i] == branch) {
                    if (best == 0 || t_updated[i] > t_updated[best] ||
                        (t_updated[i] == t_updated[best] &&
                         t_version[i] > t_version[best])) best = i
                }
            }
            if (best == 0 && n == 1) best = 1
            if (best == 0) {
                printf "no-task\t\t\t\n"
                exit
            }
            printf "%s\t%s\t%s\t%s\n", \
                t_status[best], t_id[best], t_branch[best], t_updated[best]
        }
    ' "$file" 2>/dev/null || true
}

concord_map_state() {
    # concord_map_state STATUS -> session_state, or `unknown` for a status
    # that is not a run signal. The map uses only what an agent reported to
    # Concord: active/assigned/handoff_offered are a turn in flight, blocked
    # is a blocker, and review_ready/handed_off/complete/closed are a finished
    # run. Concord has no failed or refused status, so those stay the result
    # file's and the refusal file's words, never an inference from this file.
    case "${1:-}" in
        active|assigned|handoff_offered) printf 'working' ;;
        blocked) printf 'blocked' ;;
        review_ready|handed_off|complete|closed) printf 'done' ;;
        *) printf 'unknown' ;;
    esac
}

concord_evidence() {
    # concord_evidence NAME [CHECKS] -> the evidence block from the Concord
    # export. `concord_status` is the raw status an agent reported and
    # `concord_reason` says why there is no verdict (missing, corrupt,
    # no-task, unknown-status) or `task` when there is. A missing or corrupt
    # file is `unknown`/concord-missing|concord-corrupt, never a guessed
    # `working`, so auto can name the fallback instead of failing silently.
    local name="$1" checks="${2:-}"
    local wt="$ROOT/.worktrees/$name" file branch record
    local status task tbranch updated state rule matched reason concord_checks
    file=$(concord_file "$wt")
    branch=$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
    concord_checks=""

    if [ ! -e "$file" ]; then
        state=unknown; rule=concord-missing; matched=''; reason=missing
        concord_checks="check: concord ($file): no"
    elif ! concord_validate "$file"; then
        state=unknown; rule=concord-corrupt; matched=''; reason=corrupt
        concord_checks="check: concord ($file): corrupt"
    else
        concord_checks="check: concord ($file): yes"
        record=$(concord_task_record "$file" "$branch")
        IFS=$'\t' read -r status task tbranch updated <<<"$record" || true
        if [ -z "$status" ] || [ "$status" = no-task ]; then
            state=unknown; rule=concord-no-task; matched=''; reason=no-task
            concord_checks+=$'\n'"check: concord-task (branch ${branch:-?}): no"
        else
            concord_checks+=$'\n'"check: concord-task ($task): status=$status branch=${tbranch:--}"
            state=$(concord_map_state "$status")
            if [ "$state" = unknown ]; then
                rule=concord-unknown-status
                reason=unknown-status
                matched="task $task status=$status"
            else
                rule=concord-task
                reason=task
                matched="task $task status=$status branch=${tbranch:--}"
            fi
        fi
    fi
    [ -z "$checks" ] || concord_checks="$checks"$'\n'"$concord_checks"
    printf 'state=%s\nsource=concord\nrule=%s\nmatched=%s\nconcord_status=%s\nconcord_task=%s\nconcord_reason=%s\nwindow_lines=0\nwindow_sha256=\nstable_scans=0\n%s\n' \
        "$state" "$rule" "${matched:0:200}" "${status:-}" "${task:-}" \
        "$reason" "$concord_checks"
}

# The classifier's window, shared by emit_evidence and the status view.
EV_PANE=''
EV_LINES=0
EV_SHA=''

emit_evidence() {
    # emit_evidence STATE RULE MATCHED SCANS CHECKS [SOURCE] -> the evidence
    # block. The first line is `state=...` because session_state reads only
    # that; everything after it is what --explain shows line by line. `source`
    # names what produced the verdict (pane, log, result-file or refusal) and
    # is additive: the keys that were already there keep their meaning.
    # that; everything after it is what --explain shows line by line. SOURCE
    # names what produced the verdict (pane, result-file or refusal).
    local state="$1" rule="$2" matched="$3" scans="$4" checks="$5" source="${6:-pane}"
    printf 'state=%s\nsource=%s\nrule=%s\nmatched=%s\nwindow_lines=%s\nwindow_sha256=%s\nstable_scans=%s\n' \
        "$state" "$source" "$rule" "${matched:0:200}" "$EV_LINES" "$EV_SHA" "$scans"
    [ -z "$checks" ] || printf '%s\n' "$checks"
    printf 'pane_begin\n%s\npane_end\n' "$EV_PANE"
}

classify_state() {
    # classify_state NAME [WINDOW] [SOURCE] -> evidence block; line one is
    # `state=done|refused|working|idle|unknown|missing`. SOURCE is pane (the
    # default), log, concord or auto. Read-only: captures and reads files
    # only, never sends, stops or writes. A first pane scan that no rule claims
    # is captured again after a pause, and only the same normalised window
    # twice becomes `unknown`.
    local name="$1" window="${2:-$REFUSAL_WINDOW}" source="${3:-pane}"
    local session="fb-$name" wt="$ROOT/.worktrees/$name" tmux
    local sentence result pane chrome norm norm2 base_checks checks
    local has_session=0 logblock logstate
    local cblock cstate creason pane_block pane_state
    tmux=$(tmux_bin 2>/dev/null || true)

    EV_PANE=''
    EV_LINES=0
    EV_SHA=''

    if [ -n "$tmux" ] && "$tmux" has-session -t "$session" 2>/dev/null; then
        has_session=1
        checks="check: session (fb-$name): yes"
    else
        checks="check: session (fb-$name): no"
    fi

    # Only the pane needs a live session. The turn log and the Concord export
    # are files, so they still answer after the TUI is gone; auto decides
    # after reading them.
    if [ "$source" = pane ] && [ "$has_session" = 0 ]; then
        emit_evidence missing no-session '' 0 "$checks"
        return 0
    fi

    # A refusal recorded by start outranks every source: the turn ends, the
    # sentence scrolls away and the prompt comes back, but the account is
    # still penalised. stop removes the file.
    sentence=$(refusal_recorded "$wt")
    checks+=$'\n'"check: recorded-refusal ($REFUSAL_FILE): $([ -n "$sentence" ] && printf yes || printf no)"
    if [ -n "$sentence" ]; then
        emit_evidence refused recorded-refusal "$sentence" 0 "$checks" refusal
        return 0
    fi
    base_checks=$checks

    result=$(result_state "$wt")
    base_checks+=$'\n'"check: result-file ($RESULT_FILE): ${result:-no}"
    case "$result" in
        done|blocked|failed)
            # The result file names the outcome and stays the authority, so a
            # blocked or failed run must not be reported as done: a wait
            # contract built on `done` would otherwise call failure success.
            emit_evidence "$result" result-file "$result" 0 "$base_checks" result-file
            return 0
            ;;
    esac

    if [ "$source" = log ]; then
        turn_log_evidence "$name" "$base_checks"
        return 0
    fi

    # auto prefers what the client recorded: the turn log first, then the
    # Concord export, and the pane only when neither has a verdict.
    if [ "$source" = auto ]; then
        logblock=$(turn_log_evidence "$name" "$base_checks")
        logstate=$(evidence_field "$logblock" turn_state)
        if [ -n "$logstate" ] && [ "$logstate" != unknown ]; then
            printf '%s\n' "$logblock"
            return 0
        fi
        base_checks+=$'\n'"check: log-verdict: ${logstate:-unknown}"
    fi

    if [ "$source" = concord ] || [ "$source" = auto ]; then
        cblock=$(concord_evidence "$name" "$base_checks")
        cstate=$(evidence_field "$cblock" state)
        creason=$(evidence_field "$cblock" concord_reason)
        if [ "$source" = concord ] || [ "$cstate" != unknown ]; then
            # Concord answered. When a pane is also present and disagrees,
            # name the loser so the disagreement is visible instead of silent;
            # the pane never outranks an explicit --source concord, it is only
            # reported.
            if [ "$has_session" = 1 ]; then
                pane_block=$(classify_state "$name" "$window" pane)
                pane_state=$(evidence_field "$pane_block" state)
                if [ "$pane_state" != "$cstate" ]; then
                    cblock+=$'\n'"loser=pane"$'\n'"loser_state=$pane_state"
                fi
            fi
            printf '%s\n' "$cblock"
            return 0
        fi
        # Neither file has a verdict: fall back to the pane, naming each
        # reason (missing, corrupt, no-task or unknown-status) so the fallback
        # is evidence rather than an accidental `unknown`.
        base_checks+=$'\n'"check: concord-verdict: ${creason:-unknown}"
        if [ "$has_session" = 0 ]; then
            emit_evidence missing no-session '' 0 "$base_checks"
            return 0
        fi
    fi

    EV_PANE=$("$tmux" capture-pane -p -t "$session" -S "-$window" 2>/dev/null || true)
    EV_LINES=$(printf '%s' "$EV_PANE" | awk 'END { print NR }')
    chrome=$(printf '%s\n' "$EV_PANE" | tail -n 12)
    classify_chrome "$EV_PANE" "$chrome"
    if [ -n "$PANE_STATE" ]; then
        EV_SHA=$(printf '%s\n' "$EV_PANE" | normalise_window | sha256_hex)
        emit_evidence "$PANE_STATE" "$PANE_RULE" "$PANE_MATCHED" 1 \
            "$base_checks"$'\n'"$PANE_CHECKS"
        return 0
    fi

    # Nothing claimed the first scan. A boot frame or a mid-repaint must not
    # raise `unknown`: capture again, and let a pane that settled into a known
    # state be classified by that state.
    norm=$(printf '%s\n' "$EV_PANE" | normalise_window)
    sleep "$UNKNOWN_RESCAN_DELAY"
    EV_PANE=$("$tmux" capture-pane -p -t "$session" -S "-$window" 2>/dev/null || true)
    EV_LINES=$(printf '%s' "$EV_PANE" | awk 'END { print NR }')
    chrome=$(printf '%s\n' "$EV_PANE" | tail -n 12)
    norm2=$(printf '%s\n' "$EV_PANE" | normalise_window)
    EV_SHA=$(printf '%s\n' "$norm2" | sha256_hex)
    classify_chrome "$EV_PANE" "$chrome"
    checks="$base_checks"$'\n'"$PANE_CHECKS"$'\n'"check: stable-window: $([ "$norm" = "$norm2" ] && printf yes || printf no)"
    if [ -n "$PANE_STATE" ]; then
        emit_evidence "$PANE_STATE" "$PANE_RULE" "$PANE_MATCHED" 2 "$checks"
    elif [ "$norm" = "$norm2" ]; then
        emit_evidence unknown no-rule-matched '' 2 "$checks"
    else
        # Changing but unrecognised: not enough evidence to call it unknown.
        # Keep the old safe failure mode for this scan and look again next poll.
        emit_evidence working unstable-window '' 2 "$checks"
    fi
}

session_state() {
    # session_state NAME [SOURCE] -> done|blocked|failed|refused|working|idle|
    # unknown|missing. SOURCE defaults to pane, so every existing caller keeps
    # its meaning; sessions passes its own --source through.
    local block first
    block=$(classify_state "$1" "$REFUSAL_WINDOW" "${2:-pane}")
    first=${block%%$'\n'*}
    printf '%s' "${first#state=}"
}

session_activity() {
    # session_activity NAME -> epoch of last tmux activity; fails when unknown
    local tmux activity
    tmux=$(tmux_bin 2>/dev/null || true)
    [ -n "$tmux" ] || return 1
    activity=$("$tmux" display-message -p -t "fb-$1" '#{session_activity}' 2>/dev/null || true)
    is_num "$activity" || return 1
    printf '%s' "$activity"
}

idle_seconds() {
    # idle_seconds NAME -> non-negative seconds since tmux activity, or empty
    local activity
    activity=$(session_activity "$1" 2>/dev/null || true)
    is_num "$activity" || return 0
    local now elapsed
    now=$(date +%s)
    elapsed=$((now - activity))
    [ "$elapsed" -ge 0 ] || elapsed=0
    printf '%s' "$elapsed"
}

