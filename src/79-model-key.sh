# ---- the client's global model key ----
# `--model` is the only way to pick a model for a launch, but the picker writes
# it to the one settings.json every launch shares, so a launch that leaves the
# key on its own choice changes every later launch that passes no --model. The
# snapshot is taken before the switch, the switch runs under a lock, and the
# old value goes back once the brief is submitted.
model_settings_path() {
    # model_settings_path -> the client's settings.json. Credentials, the
    # device key and the chat history live beside it, so it is the model key
    # alone that can be moved without logging the account out.
    printf '%s/settings.json' "$(freebuff_config_dir)"
}

model_lock_dir() {
    # model_lock_dir -> the mutex every model switch shares. It lives in the
    # config dir, next to the key it guards, so two worktrees of this
    # repository and a second terminal all see the same one.
    printf '%s/.supervisor-model.lock' "$(freebuff_config_dir)"
}

model_key_value() {
    # model_key_value FILE -> the value of the client's model key, one line,
    # empty when the file or the key is missing. The file is JSON, but the key
    # is one line and the tool ships no JSON helper, so it is read with sed.
    [ -f "${1-}" ] || return 0
    sed -nE 's/^[[:space:]]*"freebuffModelKey"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' \
        "$1" 2>/dev/null | head -n 1 || true
}

model_key_snapshot() {
    # model_key_snapshot FILE -> 0 with MODEL_KEY_MODE `value` (FILE names a
    # model) or `none` (FILE has no key, or no FILE) and MODEL_KEY_SAVED set to
    # the value to put back. 1 with MODEL_KEY_ERROR when FILE cannot be read:
    # a launch that cannot put the key back must not move it.
    local file=${1-}
    MODEL_KEY_SAVED=''
    MODEL_KEY_MODE=''
    if [ ! -e "$file" ]; then
        MODEL_KEY_MODE=none
        return 0
    fi
    if [ ! -f "$file" ] || [ ! -r "$file" ]; then
        MODEL_KEY_ERROR="cannot read the model key in $file"
        return 1
    fi
    MODEL_KEY_SAVED=$(model_key_value "$file")
    if [ -n "$MODEL_KEY_SAVED" ]; then
        MODEL_KEY_MODE=value
    else
        MODEL_KEY_MODE=none
    fi
    return 0
}

model_key_write() {
    # model_key_write FILE VALUE -> 0 when FILE now carries the key as VALUE.
    # Only the one value changes, so the client's other keys and the file's
    # layout stay as they were, and the result is read back: a write that
    # silently did nothing is a failure, not a success.
    local file=${1-} value=${2-} esc tmp
    [ -f "$file" ] || return 1
    esc=$(printf '%s' "$value" | sed 's/[\\&|]/\\&/g')
    tmp="$file.tmp.$$"
    if ! sed -E "s|^([[:space:]]*\"freebuffModelKey\"[[:space:]]*:[[:space:]]*)\"[^\"]*\"|\1\"$esc\"|" \
        "$file" >"$tmp" 2>/dev/null; then
        rm -f "$tmp"
        return 1
    fi
    if ! mv -f "$tmp" "$file" 2>/dev/null; then
        rm -f "$tmp"
        return 1
    fi
    [ "$(model_key_value "$file")" = "$value" ]
}

model_key_drop() {
    # model_key_drop FILE -> 0 when FILE no longer names the key. Putting back
    # a config that had no key means removing the line the switch added, and
    # the separator a JSON object keeps on the member before it: the key is
    # often the last member, and a dangling comma would make the file invalid
    # and the client reset every setting. The other keys are left alone. A
    # compact file that keeps the key on a shared line is refused rather than
    # rewritten, because deleting that line would take those keys with it.
    local file=${1-} tmp
    [ -f "$file" ] || return 0
    grep -qE '^[[:space:]]*"freebuffModelKey"[[:space:]]*:[[:space:]]*"[^"]*"[[:space:]]*,?[[:space:]]*$' \
        "$file" 2>/dev/null || return 1
    tmp="$file.tmp.$$"
    if ! awk '
        { line[NR] = $0 }
        END {
            n = 0; dropped = 0
            for (i = 1; i <= NR; i++) {
                if (line[i] ~ /^[[:space:]]*"freebuffModelKey"[[:space:]]*:/) {
                    dropped = 1
                    continue
                }
                keep[++n] = line[i]
            }
            if (!dropped) { for (i = 1; i <= n; i++) print keep[i]; exit }
            for (i = 1; i < n; i++)
                if (keep[i + 1] ~ /^[[:space:]]*[}\]]/) sub(/,[[:space:]]*$/, "", keep[i])
            for (i = 1; i <= n; i++) print keep[i]
        }' "$file" >"$tmp" 2>/dev/null; then
        rm -f "$tmp"
        return 1
    fi
    if ! mv -f "$tmp" "$file" 2>/dev/null; then
        rm -f "$tmp"
        return 1
    fi
    [ -z "$(model_key_value "$file")" ]
}

model_lock_acquire() {
    # model_lock_acquire TIMEOUT POLL -> 0 with MODEL_LOCK_HELD=1, 1 when no
    # lock came free in TIMEOUT. mkdir is the mutex: it is atomic on every
    # filesystem the phone has and needs no flock, which coreutils alone does
    # not promise. The owner is recorded inside, so a launch killed with
    # SIGKILL is taken over instead of blocking every later switch.
    local dir lock_t=${1-} poll=${2-} owner deadline blind=0
    dir=$(model_lock_dir)
    MODEL_LOCK_HELD=0
    mkdir -p -- "$(dirname -- "$dir")" 2>/dev/null || true
    deadline=$(( $(date +%s) + lock_t ))
    while :; do
        if mkdir -- "$dir" 2>/dev/null; then
            printf '%s %s\n' "$$" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
                >"$dir/owner" 2>/dev/null || true
            MODEL_LOCK_HELD=1
            return 0
        fi
        owner=$(sed -n '1s/ .*//p' "$dir/owner" 2>/dev/null || true)
        if [ -z "$owner" ]; then
            # A lock with no owner was left by a launch killed between the
            # mkdir and the owner line: it can be waited for only until that
            # gap is closed, not for the whole timeout.
            blind=$((blind + 1))
            [ "$blind" -le 10 ] || { rm -rf -- "$dir" 2>/dev/null || true; blind=0; }
        elif ! kill -0 "$owner" 2>/dev/null; then
            # The owner is gone, so the lock it left cannot be waited for.
            rm -rf -- "$dir" 2>/dev/null || true
            blind=0
        else
            blind=0
        fi
        [ "$(date +%s)" -lt "$deadline" ] || return 1
        sleep "$poll"
    done
}

model_lock_release() {
    # model_lock_release -> drop the lock this process holds, and nothing when
    # it holds none. The EXIT trap calls it too, so a launch that dies between
    # the switch and the restore cannot leave the lock behind.
    [ "$MODEL_LOCK_HELD" = 1 ] || return 0
    rm -rf -- "$(model_lock_dir)" 2>/dev/null || true
    MODEL_LOCK_HELD=0
    return 0
}

model_key_take() {
    # model_key_take WORKTREE -> 0 with the lock held and the key snapshotted,
    # 1 with MODEL_KEY_ERROR saying why not. Nothing is switched until this
    # returns 0: waiting for the lock is what keeps two launches from
    # interleaving their writes, and reading the key first is what makes the
    # restore possible at all.
    local wt=${1-} file
    file=$(model_settings_path)
    MODEL_KEY_ERROR=''
    MODEL_KEY_SAVED=''
    MODEL_KEY_MODE=''
    [ "$MODEL_LOCK_HELD" = 0 ] || return 0
    if ! model_lock_acquire "$MODEL_LOCK_TIMEOUT" "$MODEL_LOCK_POLL"; then
        MODEL_KEY_ERROR="another launch held $(model_lock_dir) for ${MODEL_LOCK_TIMEOUT}s"
        return 1
    fi
    if ! model_key_snapshot "$file"; then
        model_lock_release
        return 1
    fi
    ready_note "$wt" "model_key=before value=${MODEL_KEY_SAVED:-none} file=$file"
    return 0
}

model_key_put_back() {
    # model_key_put_back WORKTREE -> write the snapshot back, release the lock
    # and record both in .supervisor.log. It is called once the brief is
    # submitted and from the EXIT trap, so a launch that failed at any point
    # after the switch puts the key back too. A restore that fails is not
    # fatal — the brief may already be sent — but it is never silent.
    local wt=${1-} file ok=0
    [ "$MODEL_LOCK_HELD" = 1 ] || return 0
    file=$(model_settings_path)
    case "$MODEL_KEY_MODE" in
        value) model_key_write "$file" "$MODEL_KEY_SAVED" && ok=1 ;;
        none) model_key_drop "$file" && ok=1 ;;
        *) ok=0 ;;
    esac
    model_lock_release
    if [ "$ok" = 1 ]; then
        ready_note "$wt" "model_key=restored value=${MODEL_KEY_SAVED:-none} file=$file"
    else
        ready_note "$wt" "model_key=restore-failed wanted=${MODEL_KEY_SAVED:-none} file=$file"
    fi
    MODEL_KEY_MODE=''
    return 0
}

brief_jitter_max() {
    # brief_jitter_max MAX_SESSIONS -> upper bound for the random delay before
    # a send. Only a pool of several slots is paced: one slot cannot fire two
    # starts at once. FREEBUFF_START_JITTER overrides it, 0 disables the wait.
    local max=$1 bound
    [ "${max:-0}" -gt 1 ] || {
        printf '0'
        return 0
    }
    bound=${FREEBUFF_START_JITTER:-$((max * 2))}
    is_num "$bound" || bound=0
    printf '%s' "$bound"
}

