# ---- the wake lock ----
# The opt-in Termux partial wake lock (#99). With the screen off, Doze can
# suspend the CPU and Android can reap the app, which takes the detached tmux
# server, the autostop watcher and `gui --serve` with it; a wake lock is the
# operator's mitigation, and the tool can ask for one. It only asks and
# records the answer: termux-wake-lock has no status query, so nothing here
# can claim the lock is still held.
wake_lock_state() {
    # wake_lock_state WORKTREE -> the last value start recorded, empty when no
    # start asked for a lock. This is evidence of what was acquired at launch,
    # not a live status.
    local wt=$1 value
    value=$(grep -o 'wake_lock=[a-z]*' "$wt/.supervisor.log" 2>/dev/null |
        tail -n 1 | cut -d= -f2 || true)
    printf '%s' "$value"
}

wake_lock_acquire() {
    # wake_lock_acquire WORKTREE -> 0 when termux-wake-lock ran, 1 when it is
    # missing or failed. Never fatal: a phone without the binary still runs,
    # unprotected, and one line says which part is missing. The tool never
    # releases the lock: it is service-scoped, so `stop` on one session would
    # unlock every session and the GUI.
    local wt=$1 bin rc=0
    if bin=$(command -v termux-wake-lock 2>/dev/null); then
        "$bin" >/dev/null 2>&1 || rc=$?
        if [ "$rc" -eq 0 ]; then
            ready_note "$wt" 'wake_lock=acquired'
            return 0
        fi
        ready_note "$wt" 'wake_lock=failed'
        note "wake_lock=failed: $bin exited $rc; the session is not protected from Doze"
        return 1
    fi
    ready_note "$wt" 'wake_lock=unavailable'
    note 'wake_lock=unavailable: termux-wake-lock is not installed; the session is not protected from Doze (pkg install termux-tools)'
    return 1
}

