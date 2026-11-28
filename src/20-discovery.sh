# ---- tmux, freebuff and git discovery ----
# Where tmux, freebuff, the repository slug and the worktree excludes come
# from: the only places that look outside this file for the environment.
repo_slug() {
    local url
    url=$(git -C "$ROOT" remote get-url origin 2>/dev/null || true)
    [ -n "$url" ] || return 0
    printf '%s' "$url" |
        sed -E 's#^git@github\.com:##; s#^https://github\.com/##; s#\.git$##'
}

tmux_bin() {
    local cache path
    if [ -n "${FREEBUFF_TMUX:-}" ]; then
        printf '%s' "$FREEBUFF_TMUX"
        return 0
    fi
    if command -v tmux >/dev/null 2>&1; then
        command -v tmux
        return 0
    fi
    cache="${XDG_CACHE_HOME:-$HOME/.cache}/wireless-adb-keeper/tmux.path"
    if [ -x "$cache" ]; then
        cat "$cache"
        return 0
    fi
    if command -v nix-shell >/dev/null 2>&1; then
        path=$(nix-shell -p tmux --run 'command -v tmux' 2>/dev/null | tail -n 1 || true)
        if [ -n "$path" ] && [ -x "$path" ]; then
            mkdir -p "$(dirname "$cache")" 2>/dev/null || true
            printf '%s' "$path" >"$cache" 2>/dev/null || true
            printf '%s' "$path"
            return 0
        fi
    fi
    return 1
}

freebuff_bin() {
    if [ -n "${FREEBUFF_BIN:-}" ]; then
        printf '%s' "$FREEBUFF_BIN"
        return 0
    fi
    if command -v freebuff >/dev/null 2>&1; then
        command -v freebuff
        return 0
    fi
    if [ -x "$HOME/.local/bin/freebuff" ]; then
        printf '%s' "$HOME/.local/bin/freebuff"
        return 0
    fi
    return 1
}

stty_bin() {
    # The raw-mode check uses GNU stty's -F. Termux ships it in coreutils, but
    # a PATH that prefers /system/bin gives toybox instead, so the binary is
    # overridable like tmux and freebuff rather than assumed.
    if [ -n "${FREEBUFF_STTY:-}" ]; then
        printf '%s' "$FREEBUFF_STTY"
        return 0
    fi
    command -v stty 2>/dev/null
}

exclude_path() {
    local common
    common=$(git -C "$ROOT" rev-parse --git-common-dir 2>/dev/null || true)
    [ -n "$common" ] || common="$ROOT/.git"
    case "$common" in
        /*) ;;
        *) common="$ROOT/$common" ;;
    esac
    printf '%s/info/exclude' "$common"
}

ensure_excludes() {
    local file entry
    file=$(exclude_path)
    mkdir -p "$(dirname "$file")"
    # .concord/ is the work-state export an agent's Concord tools write under
    # its worktree: local coordination state, like the run evidence below, and
    # never project content. Excluded here (the common dir, so every linked
    # worktree inherits it) so a run that used its work-state tools is not
    # reported dirty and cannot commit the export (#154).
    for entry in '.worktrees/' '.task.md' 'local.properties' "$RESULT_FILE" \
        '.supervisor.log' "$GH_STATE_FILE" "$BRIEF_LEDGER" "$HOURS_LEDGER" \
        '.concord/'; do
        grep -qxF "$entry" "$file" 2>/dev/null || printf '%s\n' "$entry" >>"$file"
    done
}

