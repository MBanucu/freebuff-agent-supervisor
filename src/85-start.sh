# ---- start ----
# The launch: flags, worktree, brief, tmux, readiness and submission.
start() {
    local issue="" name="" branch="" base="main" title="" url="" task_file=""
    local sdk_dir="" dry=0 nostart=0 autostop=0 idle=120 poll=5 no_gh=0 no_check=0
    local wake_lock=0
    local idle_set=0 poll_set=0 max_sessions=0 wait_slot=0 slot_wait=300
    local ready_timeout="$READY_TIMEOUT" ready_poll="$READY_POLL"
    local submit_timeout="$SUBMIT_TIMEOUT" trust_agents=0
    local prompt_text="" sent brief_hash_value jitter_max jitter=0
    local model_want=""
    local ready_rc=0 submit_rc=0 pane refusal="" title_before trust_dir
    while [ $# -gt 0 ]; do
        case "$1" in
            --issue) issue=${2:-}; shift 2 ;;
            --name) name=${2:-}; shift 2 ;;
            --branch) branch=${2:-}; shift 2 ;;
            --base) base=${2:-}; shift 2 ;;
            --task-file) task_file=${2:-}; shift 2 ;;
            --title) title=${2:-}; shift 2 ;;
            --url) url=${2:-}; shift 2 ;;
            --sdk-dir) sdk_dir=${2:-}; shift 2 ;;
            --auto-stop) autostop=1; shift ;;
            --no-gh) no_gh=1; shift ;;
            --no-check) no_check=1; shift ;;
            --wake-lock) wake_lock=1; shift ;;
            --idle-seconds) idle=${2:-}; idle_set=1; shift 2 ;;
            --poll) poll=${2:-}; poll_set=1; shift 2 ;;
            --ready-timeout) ready_timeout=${2:-}; shift 2 ;;
            --ready-poll) ready_poll=${2:-}; shift 2 ;;
            --trust-agents) trust_agents=1; shift ;;
            --submit-timeout) submit_timeout=${2:-}; shift 2 ;;
            --max-sessions) max_sessions=${2:-}; shift 2 ;;
            --wait-slot)
                wait_slot=1
                case "${2:-}" in
                    ''|*[!0-9]*) shift ;;
                    *) slot_wait=$2; shift 2 ;;
                esac
                ;;
            --dry-run) dry=1; shift ;;
            --no-start) nostart=1; shift ;;
            --prompt) prompt_text=${2:-}; shift 2 ;;
            --model)
                model_want=${2:-}
                [ -n "$model_want" ] || die "start: --model must name a model"
                shift 2
                ;;
            -h|--help) usage; exit 0 ;;
            *) die "start: unsupported argument: $1" ;;
        esac
    done

    case "$issue" in
        ''|*[!0-9]*) die "start: --issue must be a number" ;;
    esac
    name=${name:-"issue-$issue"}
    branch=${branch:-"issue/$issue"}
    valid_name "$name" || die "start: name may only contain letters, digits, _ and -"
    [ -n "$branch" ] || die "start: branch is empty"
    is_num "$idle" || die "start: --idle-seconds must be a number"
    is_num "$poll" || die "start: --poll must be a number"
    is_num "$ready_timeout" || die "start: --ready-timeout must be a number of seconds"
    [ "$ready_timeout" -ge 1 ] || die "start: --ready-timeout must be at least 1 second"
    is_duration "$ready_poll" || die "start: --ready-poll must be a positive number of seconds"
    is_num "$submit_timeout" || die "start: --submit-timeout must be a number of seconds"
    [ "$submit_timeout" -ge 1 ] || die "start: --submit-timeout must be at least 1 second"
    case "$model_want" in
        *$'\n'*|*$'\t'*) die "start: --model must be one line" ;;
    esac
    if [ "$autostop" = 0 ] && { [ "$idle_set" = 1 ] || [ "$poll_set" = 1 ]; }; then
        die "start: --idle-seconds and --poll require --auto-stop"
    fi
    is_num "$max_sessions" || die "start: --max-sessions must be a number"
    if [ "$max_sessions" = 0 ] && [ "$wait_slot" = 1 ]; then
        die "start: --wait-slot needs --max-sessions N (nothing to wait for otherwise)"
    fi
    # The environment switch is for a shell that always wants the lock on a
    # phone, so every launch does not have to repeat the flag.
    [ "${FREEBUFF_WAKE_LOCK:-}" != 1 ] || wake_lock=1

    # A missing command has to be named before a worktree is spent on it, and a
    # client that exists but cannot execute must not look like a slow launch
    # (#98). The check runs for --dry-run too, so the plan is not printed for a
    # start that cannot work; --no-check and FREEBUFF_SKIP_PREFLIGHT=1 keep the
    # old late discovery for a caller that knows its environment. freebuff is
    # only needed by a launch, gh only when this run mirrors the issue.
    if [ "$no_check" = 0 ] && [ "${FREEBUFF_SKIP_PREFLIGHT:-}" != 1 ]; then
        local -a checks=(tmux stty git)
        [ "$nostart" = 1 ] || checks=(tmux freebuff stty git)
        [ "$no_gh" = 1 ] || checks+=(gh)
        preflight "${checks[@]}"
    fi

    local slug wt session result
    slug=$(repo_slug || true)
    wt="$ROOT/.worktrees/$name"
    session="fb-$name"
    result="$wt/$RESULT_FILE"
    # The brief and its identity are known before anything is created, so a
    # duplicate is a hard error rather than a spent worktree and a strike.
    sent=$(compose_brief "$name" "$branch" "$wt" "$issue" "$prompt_text")
    brief_hash_value=$(brief_hash "$sent")
    jitter_max=$(brief_jitter_max "$max_sessions")

    if [ -z "$title" ] || [ -z "$url" ]; then
        if [ -n "$slug" ] && command -v "${GH_BIN:-gh}" >/dev/null 2>&1; then
            local meta
            meta=$("${GH_BIN:-gh}" issue view "$issue" -R "$slug" \
                --json title,url --jq '[.title,.url]|@tsv' 2>/dev/null || true)
            if [ -n "$meta" ]; then
                title=${title:-${meta%%$'\t'*}}
                url=${url:-${meta#*$'\t'}}
            fi
        fi
        title=${title:-"issue #$issue"}
        url=${url:-"https://github.com/${slug:-owner/repo}/issues/$issue"}
    fi

    if [ "$dry" = 1 ]; then
        note "worktree=$wt"
        note "branch=$branch"
        note "base=$base"
        note "session=$session"
        note "task=$wt/.task.md"
        note "result=$result"
        note "brief_hash=$brief_hash_value"
        note "brief_chars=${#sent}"
        [ "$jitter_max" = 0 ] || note "jitter_max=${jitter_max}s"
        note "ready_timeout=${ready_timeout}s ready_poll=${ready_poll}s"
        note "trust_agents=$([ "$trust_agents" = 1 ] && printf yes || printf no)"
        [ -z "$model_want" ] || note "model=$model_want"
        note "submit_timeout=${submit_timeout}s"
        [ "$wake_lock" = 0 ] || note 'wake_lock=requested'
        note "tmux=${FREEBUFF_TMUX:-tmux} -x $COLS -y $ROWS -c $wt"
        if [ "$autostop" = 1 ]; then
            note "autostop=yes idle_seconds=$idle poll=$poll"
        fi
        if [ "$max_sessions" -gt 0 ]; then
            note "max_sessions=$max_sessions live=$(live_session_count) wait_slot=$wait_slot"
        fi
        return 0
    fi

    # Every session shares one account, so a launch is pointless while the
    # limit is reached: the pane stops on the overlay and never takes input.
    # Check before spending a worktree, and wait for a slot if asked.
    if [ "$max_sessions" -gt 0 ]; then
        local live deadline
        live=$(live_session_count)
        if [ "$live" -ge "$max_sessions" ]; then
            if [ "$wait_slot" = 0 ]; then
                die "start: $live fb-* session(s) already live (--max-sessions $max_sessions); stop one or pass --wait-slot"
            fi
            deadline=$(( $(date +%s) + slot_wait ))
            note "waiting-for-slot=yes live=$live max=$max_sessions timeout=${slot_wait}s"
            while [ "$live" -ge "$max_sessions" ]; do
                if [ "$(date +%s)" -ge "$deadline" ]; then
                    die "start: still $live fb-* session(s) after ${slot_wait}s; nothing was created"
                fi
                sleep 5
                live=$(live_session_count)
                note "waiting-for-slot=yes live=$live"
            done
            note "slot-free=yes live=$live"
        fi
    fi

    if [ -e "$wt" ]; then
        die "start: worktree already exists: $wt (try status $name)"
    fi
    if git -C "$ROOT" show-ref --verify --quiet "refs/heads/$branch"; then
        die "start: branch already exists: $branch"
    fi
    if ! git -C "$ROOT" rev-parse --verify "$base^{commit}" >/dev/null 2>&1; then
        die "start: base ref not found: $base"
    fi

    # A brief already sent inside the ledger window is a hard error: the
    # vendor reads it as scripted use and answers with a strike. --no-start
    # sends nothing, so it has nothing to refuse.
    [ "$nostart" = 1 ] || refuse_sent_brief "$brief_hash_value"

    ensure_excludes
    mkdir -p "$ROOT/.worktrees"
    git -C "$ROOT" worktree add -b "$branch" "$wt" "$base" >/dev/null

    if [ -n "$sdk_dir" ]; then
        printf 'sdk.dir=%s\n' "$sdk_dir" >"$wt/local.properties"
    elif [ -f "$ROOT/local.properties" ]; then
        cp "$ROOT/local.properties" "$wt/local.properties"
    fi

    if [ -n "$task_file" ]; then
        [ -f "$task_file" ] || die "start: task file not found: $task_file"
        cp "$task_file" "$wt/.task.md"
    else
        write_task "$wt/.task.md" "$slug" "$issue" "$title" "$url" "$branch" "$base"
    fi

    note "created=$wt"
    note "branch=$branch"
    note "task=$wt/.task.md"
    note "result=$result"

    if [ "$nostart" = 1 ]; then
        [ -z "$model_want" ] ||
            note "model=$model_want applied=no (--no-start launches no session)"
        return 0
    fi

    local tmux fb cmd
    tmux=$(tmux_bin) || die "start: tmux not found; install tmux or set FREEBUFF_TMUX"
    fb=$(freebuff_bin) || die "start: freebuff not found; set FREEBUFF_BIN"
    # The lock is asked for after the preflight and before tmux starts, so the
    # server it is meant to protect is never launched without it. The result is
    # recorded for status and sessions; it is never fatal and never released.
    if [ "$wake_lock" = 1 ]; then
        wake_lock_acquire "$wt" || true
    fi
    # Never pass --trust-agents unless asked: it loads repository-supplied
    # agent files and mcp.json with the user's permissions. A worktree that
    # needs it says so through the trust prompt, which start reports below.
    if [ "$trust_agents" = 1 ]; then
        printf -v cmd 'TERM=xterm-256color %q --cwd %q --trust-agents' "$fb" "$wt"
    else
        printf -v cmd 'TERM=xterm-256color %q --cwd %q' "$fb" "$wt"
    fi
    "$tmux" new-session -d -s "$session" -x "$COLS" -y "$ROWS" -c "$wt" "$cmd"

    wait_ready "$tmux" "$session" "$wt" "$ready_timeout" "$ready_poll" || ready_rc=$?
    if [ "$ready_rc" -eq 2 ]; then
        # The overlay is a refusal, not a slow start. Its Enter key takes over
        # another live session, so no keys are typed at all; the worktree and
        # the sentence are kept so status reports refused until stop.
        pane=$("$tmux" capture-pane -p -t "$session" -S "-$REFUSAL_WINDOW" 2>/dev/null || true)
        refusal=$(refusal_sentence "$pane")
        [ -n "$refusal" ] || refusal='Freebuff refused the launch'
        refusal_record "$wt" "$refusal"
        "$tmux" kill-session -t "$session" 2>/dev/null || true
        note "session=$session"
        refusal_notes "$refusal" "$pane" "$tmux" "$session"
        note "refusal=$refusal"
        note 'sent=no'
        die "start: Freebuff refused the launch before the brief was sent: $refusal (no keys typed; worktree kept at $wt)"
    fi
    if [ "$ready_rc" -eq 3 ]; then
        # The trust gate is a user decision about repository-supplied code.
        # Nothing is answered: name the directory and both ways to proceed,
        # then stop the session so it cannot sit on the prompt forever.
        pane=$("$tmux" capture-pane -p -t "$session" -S -15 2>/dev/null || true)
        trust_dir="$wt/.agents"
        if [ ! -d "$trust_dir" ] && [ -d "$ROOT/.worktrees/.agents" ]; then
            trust_dir="$ROOT/.worktrees/.agents"
        fi
        "$tmux" kill-session -t "$session" 2>/dev/null || true
        ready_note "$wt" "ready=trust-prompt elapsed=${READY_ELAPSED}s timeout=${ready_timeout}s poll=${ready_poll}s session=$session dir=$trust_dir"
        note "session=$session"
        note 'trust_prompt=yes'
        note "trust_dir=$trust_dir"
        note 'sent=no'
        printf '%s\n' '--- pane lines the check read ---'
        printf '%s\n' "$pane"
        if [ "$trust_agents" = 1 ]; then
            die "start: Freebuff stopped at its trust prompt for $trust_dir in $session even though --trust-agents was passed; it did not load repository-supplied agent files. No key was typed; stopped it, worktree kept ($wt)."
        fi
        die "start: Freebuff stopped at its trust prompt for $trust_dir in $session: it loads repository-supplied .agents files and mcp.json only after that directory is trusted. Answer y once in an interactive launch in $wt (freebuff --cwd $wt), or rerun start with --trust-agents to load it without asking. No key was typed; stopped it, worktree kept ($wt)."
    fi
    if [ "$ready_rc" -ne 0 ]; then
        printf '%s\n' '--- last pane lines ---'
        "$tmux" capture-pane -p -t "$session" -S -15 2>/dev/null || true
        # A pane that never reached raw input can never accept the brief, so it
        # is dead weight. Kill only the session; the worktree and branch stay.
        "$tmux" kill-session -t "$session" 2>/dev/null || true
        case "$READY_REASON" in
            stty)
                # Name the binary, the tty and its own error: a toybox stty
                # without -F, or a pty this user cannot open, is not a slow
                # cold start and must not read as one.
                ready_note "$wt" "ready=no reason=stty elapsed=${READY_ELAPSED}s timeout=${ready_timeout}s poll=${ready_poll}s session=$session tty=$READY_TTY command=$READY_STTY error=$READY_ERROR"
                die "start: raw-mode check failed in $session after ${READY_ELAPSED}s: tty=$READY_TTY command=$READY_STTY -a -F $READY_TTY error=$READY_ERROR; stopped it, worktree kept ($wt). Set FREEBUFF_STTY to a GNU stty if this one does not support -F."
                ;;
            no-tty)
                ready_note "$wt" "ready=no reason=no-tty elapsed=${READY_ELAPSED}s timeout=${ready_timeout}s poll=${ready_poll}s session=$session"
                die "start: tmux reported no pane tty for $session after ${READY_ELAPSED}s (tmux display-message -p '#{pane_tty}'); stopped it, worktree kept ($wt)."
                ;;
            no-session)
                ready_note "$wt" "ready=no reason=no-session elapsed=${READY_ELAPSED}s timeout=${ready_timeout}s poll=${ready_poll}s session=$session"
                die "start: session $session disappeared before it reached raw input after ${READY_ELAPSED}s; stopped it, worktree kept ($wt)."
                ;;
            *)
                ready_note "$wt" "ready=timeout elapsed=${READY_ELAPSED}s timeout=${ready_timeout}s poll=${ready_poll}s session=$session"
                die "start: TUI did not reach raw input in $session after ${READY_ELAPSED}s (--ready-timeout $ready_timeout, --ready-poll $ready_poll); stopped it, worktree kept ($wt). A cold first launch can need a larger --ready-timeout."
                ;;
        esac
    fi

    # The model is chosen before the brief is typed. A launch that lands on a
    # model whose hour costs two is exactly what #125 exists to stop, and the
    # picker is the only switch the client offers. A choice that cannot be
    # made or confirmed sends no brief: the session is stopped and the
    # worktree kept, like every other failed launch.
    if [ -n "$model_want" ]; then
        if ! model_choose "$tmux" "$session" "$wt" "$model_want"; then
            pane=$("$tmux" capture-pane -p -t "$session" -S "-$REFUSAL_WINDOW" 2>/dev/null || true)
            "$tmux" send-keys -t "$session" Escape 2>/dev/null || true
            "$tmux" kill-session -t "$session" 2>/dev/null || true
            note "session=$session"
            note "model_want=$model_want"
            note "model_error=$MODEL_ERROR"
            note 'sent=no'
            printf '%s\n' '--- pane lines the check read ---'
            printf '%s\n' "$pane"
            die "start: could not choose model '$model_want' in $session: $MODEL_ERROR. No brief was sent; stopped it, worktree kept ($wt)."
        fi
        # The picker's own price line is the answer to whether this run spends
        # hours: `free` means it printed no multiplier under the entry.
        ready_note "$wt" "model=$MODEL_RESOLVED price=$(model_hours_cost "$MODEL_PRICE") elapsed=${PICKER_ELAPSED}s session=$session"
    fi

    # A brief that is byte-identical across sessions reads as scripted use to
    # the vendor, which refuses the message and counts a strike. `sent` was
    # composed from the session, branch, worktree and issue, and its hash
    # cleared the ledger above, so this exact text has not been sent recently.
    if [ "$jitter_max" -gt 0 ]; then
        jitter=$((RANDOM % (jitter_max + 1)))
        note "jitter=${jitter}s max=${jitter_max}s"
        sleep "$jitter"
    fi
    # The chat title before the send is the baseline the proof compares
    # against; `Chat: New chat` becoming the task's name is one of the two
    # ways a swallowed Enter is told apart from an accepted one.
    title_before=$(chat_title "$("$tmux" capture-pane -p -t "$session" -S -12 2>/dev/null || true)")
    "$tmux" send-keys -t "$session" -l "$sent"
    sleep 0.5
    "$tmux" send-keys -t "$session" C-m

    # The Enter is not proof. A pane that is ready can still swallow it: the
    # composer clears and the session sits at the idle prompt with no turn,
    # which used to print started=yes. Wait for the input line to clear and
    # for the turn to begin (or the title to change), bounded by
    # --submit-timeout. Nothing is retyped: a brief that cannot be proven is
    # reported, not doubled.
    await_submission "$tmux" "$session" "$title_before" \
        "$submit_timeout" "$ready_poll" || submit_rc=$?
    if [ "$submit_rc" -eq 2 ]; then
        # The vendor's anti-automation answer arrives as a finished turn, not
        # as chrome: the sentence is above the resting prompt and the session
        # looks idle. Check the turn text before claiming the launch succeeded.
        pane=$("$tmux" capture-pane -p -t "$session" -S "-$REFUSAL_WINDOW" 2>/dev/null || true)
        refusal=$(refusal_sentence "$pane")
        [ -n "$refusal" ] || refusal='Freebuff refused the brief'
        refusal_record "$wt" "$refusal"
        # Reuse the #48 ledger: this exact text was refused, so it must never
        # be typed again, even after it would have aged out of the window.
        brief_ledger_mark_refused "$brief_hash_value" "$name" "$branch"
        note "session=$session"
        refusal_notes "$refusal" "$pane" "$tmux" "$session"
        note "refusal=$refusal"
        # The overlay was already on screen at the first poll, so the window
        # was not spent: name the elapsed time that proved it.
        note "submit_elapsed=${SUBMIT_ELAPSED}s"
        note 'resent=no'
        die "start: Freebuff refused the brief: $refusal (not resent; worktree kept at $wt)"
    fi
    if [ "$submit_rc" -ne 0 ]; then
        # The brief was typed but never submitted. A session that looks alive
        # and does nothing is the failure this tool exists to prevent, so say
        # sent=no, show the pane the check read, stop the session and fail.
        # The worktree and branch stay, like every other failed launch.
        pane=$("$tmux" capture-pane -p -t "$session" -S -15 2>/dev/null || true)
        ready_note "$wt" "submit=no elapsed=${SUBMIT_ELAPSED}s timeout=${submit_timeout}s poll=${ready_poll}s session=$session"
        "$tmux" kill-session -t "$session" 2>/dev/null || true
        note "session=$session"
        note 'sent=no'
        note 'submit_proof=none'
        note "submit_elapsed=${SUBMIT_ELAPSED}s timeout=${submit_timeout}s"
        note 'resent=no'
        printf '%s\n' '--- pane lines the check read ---'
        printf '%s\n' "$pane"
        die "start: the brief did not prove submission in $session after ${SUBMIT_ELAPSED}s (--submit-timeout $submit_timeout, --ready-poll $ready_poll): the turn never began and the chat title did not change. No keys were retyped, stopped it, worktree kept ($wt)."
    fi

    # Recorded only once the send is proven, so a launch that was swallowed
    # (text nobody saw) never blocks a deliberate retry with that text.
    brief_ledger_record "$brief_hash_value" "$name" "$branch"
    ready_note "$wt" "submit=yes proof=${SUBMIT_PROOF} elapsed=${SUBMIT_ELAPSED}s timeout=${submit_timeout}s poll=${ready_poll}s session=$session"
    note "session=$session"
    note 'sent=yes'
    note "submit_proof=${SUBMIT_PROOF} elapsed=${SUBMIT_ELAPSED}s"
    note "started=yes"
    "$tmux" capture-pane -p -t "$session" -S -8 2>/dev/null || true

    # The issue number is not recoverable from a live session later (the pane
    # shows a prompt, not flags), so it is written next to the worktree here
    # and every later transition reuses it.
    if [ "$no_gh" != 1 ] && [ -n "$issue" ]; then
        printf 'issue=%s\nslug=%s\nbranch=%s\nsession=%s\n' \
            "$issue" "$slug" "$branch" "$session" >"$wt/$GH_STATE_FILE"
        gh_state "$wt" working "🤖 **subagent working** — session \`$session\`, branch \`$branch\`, worktree \`.worktrees/$name\`. The label moves to \`status:blocked\` / \`status:done\` as it runs; \`spawn-freebuff-agent status $name\` is the local view."
    fi

    if [ "$autostop" = 1 ]; then
        local script log watcher_pid
        case "$0" in
            */*) script=$(cd "$(dirname "$0")" && pwd)/$(basename "$0") ;;
            *) script=$(command -v "$0" 2>/dev/null || printf '%s' "$0") ;;
        esac
        log="$wt/.supervisor.log"
        # setsid puts the watcher in its own session, so tearing down the
        # caller's process group (a closed terminal, a finished CI step) no
        # longer takes the watcher with it. It is optional; without it nohup
        # still ignores SIGHUP, but the watcher stays in the caller's group.
        if command -v setsid >/dev/null 2>&1; then
            setsid "$script" --root "$ROOT" autostop "$name" \
                --idle-seconds "$idle" --poll "$poll" </dev/null >>"$log" 2>&1 &
        else
            nohup "$script" --root "$ROOT" autostop "$name" \
                --idle-seconds "$idle" --poll "$poll" </dev/null >>"$log" 2>&1 &
        fi
        watcher_pid=$!
        # watcher_state greps .supervisor.log; a note on stdout would never be
        # seen by sessions or status.
        printf 'autostop=pid:%s\n' "$watcher_pid" >>"$log"
        note "autostop=pid:$watcher_pid"
        note "log=$log"
    fi
}

