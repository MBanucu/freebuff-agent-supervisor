# ---- state files and refusals ----
# The result file, the recorded refusal and the terminal states: what a run
# says about itself without reading the pane.
result_key() {
    # result_key FILE KEY -> value, empty when absent
    local value
    value=$(grep -m1 "^$2=" "$1" 2>/dev/null | cut -d= -f2- || true)
    printf '%s' "${value%$'\r'}"
}

result_state() {
    # result_state WORKTREE -> done|blocked|failed|unknown, empty without a file
    local file="$1/$RESULT_FILE" state
    [ -f "$file" ] || return 0
    state=$(result_key "$file" state)
    case "$state" in
        done|blocked|failed) printf '%s' "$state" ;;
        *) printf 'unknown' ;;
    esac
}

state_is_terminal() {
    # state_is_terminal STATE -> 0 when the run is over and the session can no
    # longer take a turn. Idle time is meaningless there: a done card reading
    # `idle 5495s` is a contradiction, not a clock (#57). `refused` is not in
    # this set: stop clears the refusal and the pane is still live.
    case "${1:-}" in
        done|blocked|failed|stopped) return 0 ;;
    esac
    return 1
}

refusal_recorded() {
    # refusal_recorded WORKTREE -> the recorded refusal sentence, empty when
    # the session has not been refused. This survives the pane: the vendor's
    # answer scrolls away while the account stays penalised.
    local file="$1/$REFUSAL_FILE"
    [ -f "$file" ] || return 0
    head -n 1 "$file" 2>/dev/null | tr -d '\r' || true
}

refusal_sentence() {
    # refusal_sentence TEXT -> every line of TEXT that matches a refusal,
    # joined into one line. The anti-automation answer is wrapped prose, so
    # matching lines are what names the refusal without recording the pane.
    local text=${1-} line out=''
    while IFS= read -r line; do
        printf '%s' "$line" | grep -qiE "$REFUSED_RE" || continue
        line=$(printf '%s' "$line" | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')
        [ -n "$line" ] || continue
        out+="${out:+ }$line"
    done <<<"$text"
    printf '%s' "$out"
}

refusal_record() {
    # refusal_record WORKTREE SENTENCE -> persist the state and the evidence.
    # The sentence goes to .supervisor.log (not the pane), and .refusal is
    # what keeps status at refused until stop clears it.
    local wt="$1" sentence="$2"
    [ -d "$wt" ] || return 0
    printf '%s\n' "$sentence" >"$wt/$REFUSAL_FILE"
    printf 'refused at=%s sentence=%s\n' \
        "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$sentence" >>"$wt/.supervisor.log"
}

clear_refusal() {
    # clear_refusal WORKTREE -> stop is the only thing that clears a refusal
    local wt="$1"
    [ -d "$wt" ] || return 0
    rm -f "$wt/$REFUSAL_FILE"
}

refusal_is_hours() {
    # refusal_is_hours SENTENCE -> 0 for the hours overlay, which is a refusal
    # with its own next step instead of the concurrent-session one.
    printf '%s\n' "${1-}" | grep -qiE "$HOURS_OVERLAY_RE"
}

hours_quota() {
    # hours_quota PANE -> the `N/M` usage the hours panel draws when it shows
    # one, empty otherwise. Only a fraction on a line that mentions hours
    # counts: the model line already carries a date-like `10/17`.
    printf '%s\n' "${1-}" | grep -i 'hour' |
        grep -oE '[0-9]+(\.[0-9]+)?/[0-9]+' | tail -n 1 || true
}

hours_panel() {
    # hours_panel PANE -> the `N/M` from the welcome panel's
    # `N/M hours remaining` line, empty otherwise. The phrase is required, so
    # a fraction in a sentence about hours is not read as the budget.
    printf '%s\n' "${1-}" |
        grep -iE '[0-9]+(\.[0-9]+)?/[0-9]+[[:space:]]+hours?[[:space:]]+remaining' |
        grep -oE '[0-9]+(\.[0-9]+)?/[0-9]+' | tail -n 1 || true
}

hours_footer() {
    # hours_footer PANE -> the `N/M` the footer draws next to the model, such
    # as `DeepSeek V4.1 Flash 10/17 • high`; empty otherwise. The fraction has
    # to sit next to the `•` separator, so the date-like fraction elsewhere in
    # the footer's chat title is not read as a budget.
    printf '%s\n' "${1-}" |
        grep -E '[0-9]+(\.[0-9]+)?/[0-9]+[[:space:]]+•' |
        grep -oE '[0-9]+(\.[0-9]+)?/[0-9]+' | tail -n 1 || true
}

hours_source() {
    # hours_source PANE -> `panel` when the reading sits in the hours overlay,
    # `footer` when the TUI drew the usage in its resting chrome instead.
    if printf '%s\n' "${1-}" | grep -qiE "$HOURS_OVERLAY_RE"; then
        printf 'panel'
    else
        printf 'footer'
    fi
}

hours_age_label() {
    # hours_age_label SECONDS -> a compact age for a cached reading: 47s, 47m,
    # 3h, 2d. A cached number is only ever shown with this beside it.
    local secs=${1:-0}
    if [ "$secs" -lt 60 ]; then
        printf '%ss' "$secs"
    elif [ "$secs" -lt 3600 ]; then
        printf '%sm' "$((secs / 60))"
    elif [ "$secs" -lt 86400 ]; then
        printf '%sh' "$((secs / 3600))"
    else
        printf '%sd' "$((secs / 86400))"
    fi
}

account_credentials_file() {
    # account_credentials_file -> the client's credentials.json under its
    # config root, the same root the turn log is read from.
    printf '%s/credentials.json' "$(freebuff_config_dir)"
}

account_token() {
    # account_token FILE -> the `default.authToken` the account API accepts,
    # empty when the file is absent, unreadable or carries no token. The file
    # is read once and the text after the `default` key is kept, so another
    # account's token is never used; a file without that key still answers
    # with its only authToken. No jq and no JSON parser: one sed pass.
    local file=${1-} text token
    [ -f "$file" ] && [ -r "$file" ] || return 0
    text=$(sed -e ':a' -e 'N' -e '$!ba' -- "$file" 2>/dev/null || true)
    token=$(printf '%s\n' "$text" |
        sed -e 's/.*"default"[[:space:]]*:[[:space:]]*{//' |
        sed -n 's/.*"authToken"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' |
        head -n 1)
    case "$token" in
        ''|*[[:space:]]*) return 0 ;;
    esac
    printf '%s' "$token"
}

account_hours_div() {
    # account_hours_div N -> N/5, the unit the TUI draws (105 -> 21, 25 -> 5).
    # A figure that does not divide evenly keeps one decimal rather than being
    # rounded to a number the account does not have.
    awk -v n="${1:-0}" 'BEGIN {
        v = n / 5
        if (v == int(v)) printf "%d", v
        else printf "%.1f", v
    }'
}

account_read() {
    # account_read -> 0 when the account's own usage was read from
    # ACCOUNT_URL, 1 with ACCOUNT_STATE naming why not. A 401 is its own
    # state, `unauthorized`: an expired token is a fixable thing and must not
    # read as an unknown figure or as a network failure. Everything else is
    # named and left to the caller, which falls back to the pane. The figures
    # are the daily remaining and limit divided by five, the unit the TUI
    # prints, plus the daily reset. The account answers with the whole
    # account on one line, many keys after the daily object carrying a
    # `limit` of their own, so the body is cut down to `"daily":{...}`
    # before a figure is read and a pair with `remaining` over `limit` is
    # `novalue` rather than a reading.
    local file token body rc=0 code flat daily
    ACCOUNT_STATE=''
    ACCOUNT_REMAINING=''
    ACCOUNT_LIMIT=''
    ACCOUNT_RESET=''
    ACCOUNT_HOURS=''
    file=$(account_credentials_file)
    token=$(account_token "$file")
    if [ -z "$token" ]; then
        ACCOUNT_STATE=unconfigured
        return 1
    fi
    if ! command -v curl >/dev/null 2>&1; then
        ACCOUNT_STATE=nocurl
        return 1
    fi
    # -f makes an HTTP error a non-zero exit, and -w still prints its code, so
    # one request both reads the body and tells 401 from a transport failure.
    if body=$(curl -fsS -m "$ACCOUNT_TIMEOUT" -w '\n%{http_code}' \
        -H "Authorization: Bearer $token" "$ACCOUNT_URL" 2>/dev/null); then
        rc=0
    else
        rc=$?
    fi
    code=$(printf '%s\n' "$body" | tail -n 1)
    body=$(printf '%s\n' "$body" | sed '$d')
    if [ "$rc" -ne 0 ]; then
        case "$code" in
            401) ACCOUNT_STATE=unauthorized ;;
            *) ACCOUNT_STATE=request ;;
        esac
        return 1
    fi
    # The daily object is not always first and the line continues after it
    # with `prices`, wallets and per-model limits: flatten the body and keep
    # only the first `"daily":{...}`, so a later `remaining` (1056 in the
    # live answer) or a per-model `limit` cannot be read as the budget. No
    # daily object means no budget to read.
    flat=$(printf '%s' "$body" | tr -d '\n')
    daily=$(printf '%s\n' "$flat" |
        grep -o '"daily"[[:space:]]*:[[:space:]]*{[^}]*}' | head -n 1 || true)
    ACCOUNT_REMAINING=$(printf '%s\n' "$daily" |
        grep -o '"remaining"[[:space:]]*:[[:space:]]*[0-9][0-9]*' |
        head -n 1 | sed 's/.*:[[:space:]]*//')
    ACCOUNT_LIMIT=$(printf '%s\n' "$daily" |
        grep -o '"limit"[[:space:]]*:[[:space:]]*[0-9][0-9]*' |
        head -n 1 | sed 's/.*:[[:space:]]*//')
    ACCOUNT_RESET=$(printf '%s\n' "$daily" |
        grep -o '"resetAt"[[:space:]]*:[[:space:]]*"[^"]*"' |
        head -n 1 | sed 's/^.*:[[:space:]]*"//; s/"$//')
    # The API spells the reset with milliseconds; the tool prints whole seconds.
    ACCOUNT_RESET=$(printf '%s' "$ACCOUNT_RESET" | sed 's/\.[0-9]*Z$/Z/')
    # A remaining larger than the limit it came from is a mismatched pair,
    # not a reading: it must never reach the display or the start gate.
    if ! is_num "$ACCOUNT_REMAINING" || ! is_num "$ACCOUNT_LIMIT" ||
        [ "$ACCOUNT_REMAINING" -gt "$ACCOUNT_LIMIT" ]; then
        ACCOUNT_STATE=novalue
        ACCOUNT_REMAINING=''
        ACCOUNT_LIMIT=''
        ACCOUNT_RESET=''
        return 1
    fi
    ACCOUNT_HOURS="$(account_hours_div "$ACCOUNT_REMAINING")/$(account_hours_div "$ACCOUNT_LIMIT")"
    return 0
}

hours_read() {
    # hours_read SESSION PANE -> 0 when there is an hours reading to show, 1
    # when neither the pane nor the ledger has one. A fraction in the pane is
    # the reading: it is appended to the ledger and HOURS_FRESH=1 marks it as
    # current, so the caller does not have to print an age for it. Otherwise
    # the ledger's last line is used with its age, which is what keeps a
    # stale value from being read as current. HOURS_VALUE/AGE/SOURCE carry
    # the result; AGE is 0 for a live read and empty when nothing was found.
    local session=${1-} pane=${2-} line ts
    HOURS_VALUE=''
    HOURS_AGE=''
    HOURS_SOURCE=''
    HOURS_FRESH=0
    HOURS_VALUE=$(hours_quota "$pane")
    if [ -n "$HOURS_VALUE" ]; then
        HOURS_SOURCE=$(hours_source "$pane")
        ts=$(date +%s)
        printf 'ts=%s hours=%s source=%s session=%s\n' \
            "$ts" "$HOURS_VALUE" "$HOURS_SOURCE" "$session" \
            >>"$ROOT/$HOURS_LEDGER" 2>/dev/null || true
        HOURS_AGE=0
        HOURS_FRESH=1
        return 0
    fi
    line=$(grep '^ts=[0-9][0-9]* hours=[^ ]* source=[^ ]*' \
        "$ROOT/$HOURS_LEDGER" 2>/dev/null | tail -n 1 || true)
    [ -n "$line" ] || return 1
    ts=$(printf '%s\n' "$line" | sed -n 's/^ts=\([0-9][0-9]*\) .*/\1/p')
    HOURS_VALUE=$(printf '%s\n' "$line" |
        sed -n 's/^ts=[0-9][0-9]* hours=\([^ ]*\) .*/\1/p')
    HOURS_SOURCE=$(printf '%s\n' "$line" |
        sed -n 's/^ts=[0-9][0-9]* hours=[^ ]* source=\([^ ]*\) .*/\1/p')
    if [ -z "$ts" ] || [ -z "$HOURS_VALUE" ]; then
        HOURS_VALUE=''
        HOURS_SOURCE=''
        return 1
    fi
    HOURS_AGE=$(($(date +%s) - ts))
    [ "$HOURS_AGE" -ge 0 ] || HOURS_AGE=0
    return 0
}

refusal_notes() {
    # refusal_notes SENTENCE PANE TMUX SESSION -> the refusal lines start
    # prints. Every refusal is `refused=` plus the sentence. The overlays also
    # name the next step: the hours overlay is `refused=hours` with the
    # account's N/M usage when the panel draws it and a hint naming both ways
    # out; the observed usage is also appended to the hours ledger (#108). The
    # concurrent-session overlay names the finished sessions still holding a
    # slot, because their run is already over and stopping them loses nothing.
    local refusal=${1-} pane=${2-} tmux=${3:-} session=${4-} held
    if refusal_is_hours "$refusal"; then
        note 'refused=hours'
        if [ -n "$session" ]; then
            hours_read "$session" "$pane" || true
        fi
        [ -z "$HOURS_VALUE" ] || note "hours=$HOURS_VALUE"
        held=$(finished_live_names "$tmux")
        [ -z "$held" ] || note "holding_slot=$held"
        note "hint=stop finished sessions with: $(basename "$0") gc, or wait for the daily hours to refill"
        return 0
    fi
    note 'refused=yes'
    if printf '%s\n' "$refusal" | grep -qiE "$REFUSAL_OVERLAY_RE"; then
        held=$(finished_live_names "$tmux")
        if [ -n "$held" ]; then
            note "holding_slot=$held"
            note "hint=free them with: $(basename "$0") gc"
        fi
    fi
}

