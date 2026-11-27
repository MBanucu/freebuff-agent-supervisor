# ---- the preflight ----
# What start needs before it spends a worktree. A missing command used to be
# found late: freebuff after the worktree was created, and a client that exists
# but cannot execute (the glibc binary on bionic Termux) as a 120-second
# wait_ready timeout instead of the loader error that caused it (#98). One
# `preflight=<command>` line per check names the missing command and the line
# that installs it, before anything is created.
preflight_termux() {
    # Termux detection for the hint only: PREFIX is set by the app's shell and
    # termux-wake-lock is a Termux package, so either identifies the phone.
    if [ -n "${PREFIX:-}" ]; then
        return 0
    fi
    command -v termux-wake-lock >/dev/null 2>&1
}

preflight_pkg() {
    # preflight_pkg COMMAND -> the Termux package that provides it. Only the
    # names that differ need a case: `pkg install python` is python3 and stty
    # ships inside coreutils (docs/termux.md section 3).
    case "${1:-}" in
        python3) printf 'python' ;;
        stty) printf 'coreutils' ;;
        *) printf '%s' "${1:-}" ;;
    esac
}

preflight_hint() {
    # preflight_hint COMMAND -> the install line a user can act on. On Termux
    # that is a package, except for freebuff, which is not a Termux package at
    # all (docs/termux.md section 6), so it always names the override. Elsewhere
    # tmux names FREEBUFF_TMUX and the rest name the plain install.
    local cmd=${1:-} var=''
    case "$cmd" in
        tmux) var=FREEBUFF_TMUX ;;
        freebuff) var=FREEBUFF_BIN ;;
    esac
    if [ "$cmd" != freebuff ] && preflight_termux; then
        printf 'pkg install %s' "$(preflight_pkg "$cmd")"
        return 0
    fi
    if [ -n "$var" ]; then
        printf 'install %s or set %s' "$cmd" "$var"
    else
        printf 'install %s' "$cmd"
    fi
}

preflight_run() {
    # preflight_run SECONDS CMD... -> CMD's status, or 124 when it outlives
    # SECONDS. `timeout` is not on every target (macOS ships it as gtimeout)
    # and the tool may not gain a dependency, so this is the poll-with-a-
    # deadline shape of wait_ready in tenths of a second.
    local secs=$1 pid rc=0 ticks i=0
    shift
    "$@" </dev/null >/dev/null 2>&1 &
    pid=$!
    ticks=$((secs * 10))
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$i" -ge "$ticks" ]; then
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
            return 124
        fi
        i=$((i + 1))
        sleep 0.1
    done
    wait "$pid" || rc=$?
    return "$rc"
}

preflight_die() {
    # preflight_die NAME -> the instruction the late failure used, so a caller
    # sees the same wording it did before and the preflight line above it says
    # which check failed and how to install it.
    case "${1:-}" in
        tmux) die 'start: tmux not found; install tmux or set FREEBUFF_TMUX' ;;
        freebuff) die 'start: freebuff not found; set FREEBUFF_BIN' ;;
        stty) die 'start: stty not found; install stty' ;;
        git) die 'start: git not found; install git' ;;
        *) die "start: ${1:-} not found" ;;
    esac
}

preflight() {
    # preflight COMMAND... -> one `preflight=<command> ...` line per check and
    # a final `preflight=ok`. tmux, freebuff, stty and git are fatal when
    # missing; gh, python3 and ttyd are only needed by the mode that names
    # them, so their miss is reported with optional=yes and the run goes on.
    # freebuff is probed by running --version, so a file that exists but cannot
    # execute is an error with its exit status, not a timeout later. Every
    # check runs before the caller is told to stop, so one run shows the whole
    # environment instead of one missing command per attempt.
    local name path rc optional hint timeout
    local missing='' fb_path='' fb_rc='' fb_timeout=''
    timeout=${FREEBUFF_PREFLIGHT_TIMEOUT:-$PREFLIGHT_TIMEOUT}
    is_num "$timeout" || timeout=$PREFLIGHT_TIMEOUT
    for name in "$@"; do
        optional=0
        case "$name" in
            gh|python3|ttyd) optional=1 ;;
        esac
        case "$name" in
            tmux) path=$(tmux_bin 2>/dev/null || true) ;;
            freebuff) path=$(freebuff_bin 2>/dev/null || true) ;;
            gh) path=$(command -v "${GH_BIN:-gh}" 2>/dev/null || true) ;;
            *) path=$(command -v "$name" 2>/dev/null || true) ;;
        esac
        if [ -z "$path" ]; then
            hint=$(preflight_hint "$name")
            if [ "$optional" = 1 ]; then
                note "preflight=$name missing=$name hint=$hint optional=yes"
            else
                note "preflight=$name missing=$name hint=$hint"
                missing="${missing:+$missing }$name"
            fi
            continue
        fi
        if [ "$name" = freebuff ]; then
            rc=0
            preflight_run "$timeout" "$path" --version || rc=$?
            if [ "$rc" -eq 124 ]; then
                fb_path=$path
                fb_timeout=$timeout
                note "preflight=freebuff error=timeout path=$path timeout=${timeout}s"
                continue
            fi
            if [ "$rc" -ne 0 ]; then
                fb_path=$path
                fb_rc=$rc
                note "preflight=freebuff error=exit_$rc path=$path"
                continue
            fi
        fi
        note "preflight=$name ok path=$path"
    done
    if [ -n "$missing" ] || [ -n "$fb_path" ]; then
        note 'preflight=failed'
        if [ -n "$missing" ]; then
            preflight_die "${missing%% *}"
        fi
        if [ -n "$fb_timeout" ]; then
            die "start: freebuff at $fb_path did not answer --version in ${fb_timeout}s; set FREEBUFF_BIN to a client that runs (see docs/termux.md)"
        fi
        die "start: freebuff at $fb_path exits $fb_rc, so it cannot run (a glibc binary on bionic Termux reports its missing loader this way); set FREEBUFF_BIN to a runnable client (see docs/termux.md)"
    fi
    note 'preflight=ok'
}

