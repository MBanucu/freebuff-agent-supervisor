# ---- attach, send and stop ----
# The terminal actions: attach to the pane, send a follow-up, stop explicitly.
attach() {
    local name=${1:-} tmux
    [ -n "$name" ] || die "attach: NAME is required"
    valid_name "$name" || die "attach: invalid name"
    [ -t 0 ] && [ -t 1 ] || die "attach: needs a terminal"
    tmux=$(tmux_bin) || die "attach: tmux not found"
    exec "$tmux" attach -t "fb-$name"
}

send() {
    # send NAME TEXT, or send NAME -- TEXT for text that starts with a dash.
    # `--` was previously taken as the text itself, so a message passed that
    # way typed `--` (or landed in an overlay) instead of failing (#121).
    local name='' text='' tmux pane
    while [ $# -gt 0 ]; do
        case "$1" in
            -h|--help) usage; exit 0 ;;
            --) shift; text="$*"; break ;;
            *)
                if [ -z "$name" ]; then
                    name=$1
                elif [ -z "$text" ]; then
                    text=$1
                else
                    die "send: unexpected argument: $1 (quote the text as one argument)"
                fi
                ;;
        esac
        shift
    done
    [ -n "$name" ] || die "send: NAME is required"
    valid_name "$name" || die "send: invalid name"
    [ -n "$text" ] || die "send: TEXT is required"
    tmux=$(tmux_bin) || die "send: tmux not found"
    "$tmux" has-session -t "fb-$name" 2>/dev/null ||
        die "send: session fb-$name is not running"
    # The overlay's Enter takes over and stops another live session, and the
    # hours overlay's Enter opens the model picker. Never type into either: a
    # follow-up is not worth killing a sibling agent or losing the text.
    pane=$("$tmux" capture-pane -p -t "fb-$name" -S "-$REFUSAL_WINDOW" 2>/dev/null || true)
    if printf '%s\n' "$pane" | grep -qiE "$REFUSAL_OVERLAY_RE|$HOURS_OVERLAY_RE"; then
        die "send: fb-$name is on the concurrent-session overlay or the hours overlay; no keys were sent (Enter would take over another session or open the model picker; stop it first)"
    fi
    # A released session draws no composer: Enter retries with the model
    # picker's choice and starts a new session, so the text would be lost.
    if printf '%s\n' "$pane" | grep -qiE "$RELEASED_OVERLAY_RE"; then
        die "send: fb-$name is on the released-session overlay; no keys were sent (its Enter retries with a model and starts a new session; press Enter in the pane, then send again)"
    fi
    "$tmux" send-keys -t "fb-$name" -l "$text"
    sleep 0.2
    "$tmux" send-keys -t "fb-$name" C-m
}

stop() {
    local name="" tmux graceful=0 wait=20 initial state deadline interrupted=no
    while [ $# -gt 0 ]; do
        case "$1" in
            --graceful) graceful=1; shift ;;
            --wait) wait=${2:-}; shift 2 ;;
            -h|--help) usage; exit 0 ;;
            -*) die "stop: unsupported argument: $1" ;;
            *) name=$1; shift ;;
        esac
    done
    [ -n "$name" ] || die "stop: NAME is required"
    valid_name "$name" || die "stop: invalid name"
    is_num "$wait" || die "stop: --wait must be a number"
    tmux=$(tmux_bin) || die "stop: tmux not found"

    if ! "$tmux" has-session -t "fb-$name" 2>/dev/null; then
        # The session may already be gone after a refused launch; stop is
        # still the action that clears the recorded refusal.
        clear_refusal "$ROOT/.worktrees/$name"
        note "stopped=no (fb-$name not running)"
        return 0
    fi

    if [ "$graceful" = 0 ]; then
        "$tmux" kill-session -t "fb-$name"
        clear_refusal "$ROOT/.worktrees/$name"
        note "stopped=fb-$name"
        # A plain stop is a state change too: the issue must not keep saying
        # status:working for a session that is gone.
        gh_state "$ROOT/.worktrees/$name" stopped \
            "🤖 **subagent stopped** — \`stop $name\` killed \`fb-$name\` before it finished; the worktree and branch are kept."
        return 0
    fi

    # Graceful: end the turn with Escape, then wait for the resting prompt, so
    # a kill cannot land between an edit and its commit unnoticed.
    initial=$(session_state "$name")
    case "$initial" in
        working|unknown)
            # An unknown pane is unreadable, not finished: interrupt it like a
            # busy turn and refuse the kill below if it never settles.
            "$tmux" send-keys -t "fb-$name" Escape
            interrupted=yes
            note 'graceful=escape'
            ;;
        *) note "graceful=already-$initial" ;;
    esac
    deadline=$(( $(date +%s) + wait ))
    while :; do
        state=$(session_state "$name")
        case "$state" in
            done|blocked|failed|idle|refused|missing) break ;;
        esac
        if [ "$(date +%s)" -ge "$deadline" ]; then
            break
        fi
        sleep 1
    done
    if [ "$state" = working ] || [ "$state" = unknown ]; then
        note "graceful=no state=$state waited=${wait}s"
        note "still busy: nothing was stopped; use plain 'stop $name' to kill it"
        return 1
    fi
    reap "$name" graceful \
        "pane_state=$state interrupted=$interrupted waited=${wait}s"
}

