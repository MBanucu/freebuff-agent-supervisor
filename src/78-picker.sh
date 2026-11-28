# ---- the model picker ----
# `start --model` switches the model before the brief is typed. The client
# exposes no flag for it, so the picker is driven with the keys it prints and
# every step is read back: the frame, the `›` marker walking to the chosen
# name, and the footer naming that name afterwards.
model_norm() {
    # model_norm TEXT -> lower case with runs of whitespace collapsed, so
    # `--model fast` and `--model "DeepSeek V4.1 Flash Fast"` compare the same
    # way regardless of case or spacing.
    printf '%s' "${1-}" | tr '[:upper:]' '[:lower:]' |
        sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//'
}

picker_frame() {
    # picker_frame PANE -> 0 when the /model picker is on screen. No other
    # frame draws its aid line, and the hours overlay's `choose another model`
    # does not contain this phrase.
    printf '%s\n' "${1-}" | grep -qF -- "$MODEL_PICKER_AID"
}

picker_entries() {
    # picker_entries PANE -> one `yes|no<TAB>name<TAB>price` line per entry, in
    # the order the list draws them. Inside a box, the line carrying `•` is the
    # model's name and the line under it is its price; `›` marks the
    # selection. The hours panel and the section headings are drawn in boxes
    # too, so an entry with no name is skipped.
    printf '%s\n' "${1-}" | awk '
        function trim(s) { gsub(/^[[:space:]]+/, "", s); gsub(/[[:space:]]+$/, "", s); return s }
        /^[[:space:]]*┌/ { inbox = 1; name = ""; price = ""; sel = "no"; next }
        /^[[:space:]]*└/ {
            if (inbox && name != "") printf "%s\t%s\t%s\n", sel, name, price
            inbox = 0; name = ""; price = ""
            next
        }
        inbox {
            body = $0
            sub(/^[[:space:]]*│/, "", body)
            sub(/[[:space:]]*│[[:space:]]*$/, "", body)
            body = trim(body)
            if (body == "") next
            if (body ~ /^›/) { sel = "yes"; sub(/^›[[:space:]]*/, "", body) }
            if (index(body, "•") > 0) {
                n = body
                sub(/[[:space:]]*•.*$/, "", n)
                name = trim(n)
            } else if (name != "") {
                price = trim(body)
            }
        }'
}

picker_names() {
    # picker_names PANE -> the entry names, one per line, in picker order
    picker_entries "${1-}" | cut -f2
}

picker_selected() {
    # picker_selected PANE -> the name the `›` marker sits on, empty when the
    # frame carries none (a repaint, or a list that has not drawn yet)
    picker_entries "${1-}" | awk -F'\t' '$1 == "yes" { print $2; exit }'
}

picker_price() {
    # picker_price PANE NAME -> the line the picker draws under NAME, empty
    # when it draws none. It is the only per-model price the client shows.
    picker_entries "${1-}" | awk -F'\t' -v n="$2" '$2 == n { print $3; exit }'
}

model_hours_cost() {
    # model_hours_cost PRICE -> what the picker says that model costs: `2x`
    # when an hour on it costs two, `paid` for a Paid plan, `daily` for a
    # per-day session cap, and `free` when its line carries none of those, in
    # which case the session spends none of the hour budget. The line is the
    # client's own words, so the answer is read, not assumed: `2x` and `Paid
    # plan` are different costs and must not both print as free.
    local line=${1-} mult
    mult=$(printf '%s\n' "$line" | grep -oE '[0-9]+(\.[0-9]+)?x' | head -n 1 || true)
    if [ -n "$mult" ]; then
        printf '%s' "$mult"
        return 0
    fi
    if printf '%s\n' "$line" | grep -qi 'paid plan'; then
        printf 'paid'
        return 0
    fi
    if printf '%s\n' "$line" | grep -qiE 'sessions? a day|per day'; then
        printf 'daily'
        return 0
    fi
    printf 'free'
}

model_state() {
    # model_state WORKTREE -> `NAME<TAB>HOURS` for the model start recorded in
    # .supervisor.log, empty when the run chose none. The line is the one
    # `--model` writes once the footer named the choice,
    # `model=<name> price=<free|Nx|paid|daily>`; a `model=no want=...` line is
    # a launch that sent no brief, not a choice, so it is not read here. The
    # name itself carries spaces, which is why the two values are separated
    # by a tab instead of by the line's own spaces.
    local wt=$1 line name hours
    line=$(grep -E ' model=.+ price=[^ ]+' "$wt/.supervisor.log" 2>/dev/null |
        tail -n 1 || true)
    [ -n "$line" ] || return 0
    name=$(printf '%s\n' "$line" | sed -E 's/^.* model=(.*) price=[^ ]+.*$/\1/')
    hours=$(printf '%s\n' "$line" | sed -E 's/^.* price=([^ ]+).*$/\1/')
    [ -n "$name" ] || return 0
    printf '%s\t%s' "$name" "$hours"
}

model_footer() {
    # model_footer PANE -> the model name the resting footer draws, such as
    # `DeepSeek V4.1 Flash Fast` in `... • high · /model to change`. The line
    # naming the hint is the footer; the picker's own entries also say
    # `• high`, so the hint is what tells the two apart.
    local line
    line=$(printf '%s\n' "${1-}" | grep -F -- '/model to change' |
        tail -n 1 || true)
    printf '%s' "$line" | sed -E 's/^[[:space:]]*//; s/[[:space:]]*•.*$//'
}

model_resolve() {
    # model_resolve PANE WANT -> 0 with MODEL_RESOLVED and MODEL_PRICE set to
    # the entry WANT names, 1 with MODEL_ERROR saying why not. An exact name
    # wins; after that a unique case-insensitive substring is enough (`fast`).
    # Two candidates is an error that lists them: choosing one of two would
    # spend the account's hours on a guess.
    local pane=${1-} want names exact partial count
    want=$(model_norm "${2-}")
    MODEL_RESOLVED=''
    MODEL_PRICE=''
    MODEL_ERROR=''
    MODEL_AMBIGUOUS=0
    if [ -z "$want" ]; then
        MODEL_ERROR='--model is empty'
        return 1
    fi
    names=$(picker_names "$pane")
    if [ -z "$names" ]; then
        MODEL_ERROR='the picker drew no model names'
        return 1
    fi
    exact=$(printf '%s\n' "$names" | while IFS= read -r n; do
        if [ "$(model_norm "$n")" = "$want" ]; then printf '%s\n' "$n"; fi
    done)
    if [ -n "$exact" ]; then
        MODEL_RESOLVED=$exact
    else
        partial=$(printf '%s\n' "$names" | while IFS= read -r n; do
            case "$(model_norm "$n")" in
                *"$want"*) printf '%s\n' "$n" ;;
            esac
        done)
        if [ -z "$partial" ]; then
            MODEL_ERROR="no model matches '${2-}' (the picker lists: $(printf '%s' "$names" | tr '\n' ' ' | sed -E 's/ $//'))"
            return 1
        fi
        count=$(printf '%s\n' "$partial" | awk 'END { print NR }')
        if [ "$count" -gt 1 ]; then
            MODEL_AMBIGUOUS=1
            MODEL_ERROR="'${2-}' matches $count models: $(printf '%s' "$partial" | tr '\n' ' ' | sed -E 's/ $//')"
            return 1
        fi
        MODEL_RESOLVED=$partial
    fi
    MODEL_PRICE=$(picker_price "$pane" "$MODEL_RESOLVED")
    return 0
}

model_frame_get() {
    # model_frame_get TMUX SESSION -> the pane, kept in MODEL_FRAME so the
    # search and the walk read the same capture without a second one.
    MODEL_FRAME=$("$1" capture-pane -p -t "$2" 2>/dev/null || true)
}

model_search() {
    # model_search TMUX SESSION WANT -> 0 with MODEL_RESOLVED/MODEL_PRICE set
    # and the matching frame in MODEL_FRAME, 1 with MODEL_ERROR set. The frame
    # draws only what fits 55 rows, so a name that is not on screen is not
    # absent: the arrow keys scroll the list, the marker moving is what
    # reveals the entries below the fold, so the search walks down to the end
    # of the list and then back up before calling the name missing. An
    # ambiguous name is not searched for: scrolling cannot tell two apart.
    local tmux=$1 session=$2 want=$3 last='' step=0 dir=Down
    model_frame_get "$tmux" "$session"
    model_resolve "$MODEL_FRAME" "$want" && return 0
    [ "$MODEL_AMBIGUOUS" = 0 ] || return 1
    while [ "$step" -lt "$MODEL_PICKER_STEPS" ]; do
        last=$(picker_selected "$MODEL_FRAME")
        "$tmux" send-keys -t "$session" "$dir" 2>/dev/null || true
        step=$((step + 1))
        sleep "$MODEL_PICKER_POLL"
        model_frame_get "$tmux" "$session"
        model_resolve "$MODEL_FRAME" "$want" && return 0
        [ "$MODEL_AMBIGUOUS" = 0 ] || return 1
        if [ "$(picker_selected "$MODEL_FRAME")" = "$last" ]; then
            # This end of the list is reached, so the rest is above it: walk
            # back up once, then stop.
            if [ "$dir" = Down ]; then
                dir=Up
            else
                break
            fi
        fi
    done
    # Leave MODEL_ERROR naming the entries the last frame drew, so the caller
    # can print what the list did offer.
    model_resolve "$MODEL_FRAME" "$want" || true
    return 1
}

picker_wait() {
    # picker_wait TMUX SESSION TIMEOUT POLL -> 0 when the picker frame is on
    # screen, 1 when it never drew inside TIMEOUT. PICKER_ELAPSED carries the
    # seconds spent, in tenths, for the log either way.
    local tmux=$1 session=$2 timeout=$3 poll=$4 frame='' i=0 polls
    polls=$(ready_polls "$timeout" "$poll")
    while [ "$i" -lt "$polls" ]; do
        frame=$("$tmux" capture-pane -p -t "$session" 2>/dev/null || true)
        if picker_frame "$frame"; then
            PICKER_ELAPSED=$(ready_elapsed "$((i + 1))" "$poll")
            return 0
        fi
        i=$((i + 1))
        sleep "$poll"
    done
    PICKER_ELAPSED=$(ready_elapsed "$i" "$poll")
    return 1
}

model_choose() {
    # model_choose TMUX SESSION WORKTREE WANT -> 0 when the footer names the
    # chosen model, 1 when it does not, with MODEL_ERROR saying why. The keys
    # are the picker's own: `/model`, the arrow keys its aid line prints, and
    # Enter. The selection is read back after every press, so a list that
    # moved, or one that does not wrap, is followed instead of counted, and
    # Enter is pressed only once the `›` marker sits on the wanted name.
    local tmux=$1 session=$2 wt=$3 want=$4
    local frame='' selected target names cur tgt key dir='' step=0 footer
    local moved polls i norm_target
    "$tmux" send-keys -t "$session" -l '/model' 2>/dev/null || true
    sleep "$MODEL_PICKER_POLL"
    "$tmux" send-keys -t "$session" C-m 2>/dev/null || true
    if ! picker_wait "$tmux" "$session" "$MODEL_PICKER_TIMEOUT" "$MODEL_PICKER_POLL"; then
        MODEL_ERROR='/model did not open the picker'
        ready_note "$wt" "model=no want=$want reason=picker-timeout elapsed=${PICKER_ELAPSED}s session=$session"
        return 1
    fi
    # The frame draws only part of the catalog, so the search scrolls the list
    # before it calls a name absent.
    if ! model_search "$tmux" "$session" "$want"; then
        ready_note "$wt" "model=no want=$want reason=resolve elapsed=${PICKER_ELAPSED}s session=$session"
        "$tmux" send-keys -t "$session" Escape 2>/dev/null || true
        return 1
    fi
    target=$MODEL_RESOLVED
    frame=$MODEL_FRAME
    while :; do
        selected=$(picker_selected "$frame")
        [ "$(model_norm "$selected")" != "$(model_norm "$target")" ] || break
        if [ "$step" -ge "$MODEL_PICKER_STEPS" ]; then
            MODEL_ERROR="the picker never moved the selection to '$target' (it stayed on '${selected:-none}' after $MODEL_PICKER_STEPS keys)"
            ready_note "$wt" "model=no want=$want reason=selection-stuck steps=$step session=$session"
            "$tmux" send-keys -t "$session" Escape 2>/dev/null || true
            return 1
        fi
        names=$(picker_names "$frame")
        cur=$(printf '%s\n' "$names" | grep -nxF -- "${selected:-}" |
            head -n 1 | cut -d: -f1 || true)
        tgt=$(printf '%s\n' "$names" | grep -nxF -- "$target" |
            head -n 1 | cut -d: -f1 || true)
        if [ -z "$dir" ]; then
            if is_num "$cur" && is_num "$tgt" && [ "$tgt" -lt "$cur" ]; then
                dir=Up
            else
                dir=Down
            fi
        fi
        key=$dir
        "$tmux" send-keys -t "$session" "$key" 2>/dev/null || true
        step=$((step + 1))
        sleep "$MODEL_PICKER_POLL"
        frame=$("$tmux" capture-pane -p -t "$session" 2>/dev/null || true)
        moved=$(picker_selected "$frame")
        if [ "$moved" = "$selected" ]; then
            # At an end of the list: it does not wrap, so walk back instead of
            # pressing into the edge until the step guard gives up.
            case "$key" in
                Up) dir=Down ;;
                *) dir=Up ;;
            esac
        fi
    done
    "$tmux" send-keys -t "$session" C-m 2>/dev/null || true
    # The Enter is not proof: the footer is. Read it back until it names the
    # chosen model and the picker frame is gone, bounded like every other wait.
    norm_target=$(model_norm "${target%% · *}")
    polls=$(ready_polls "$MODEL_PICKER_TIMEOUT" "$MODEL_PICKER_POLL")
    i=0
    while [ "$i" -lt "$polls" ]; do
        frame=$("$tmux" capture-pane -p -t "$session" 2>/dev/null || true)
        footer=$(model_footer "$frame")
        if ! picker_frame "$frame" &&
            [ "$(model_norm "${footer%% · *}")" = "$norm_target" ]; then
            PICKER_ELAPSED=$(ready_elapsed "$((i + 1))" "$MODEL_PICKER_POLL")
            return 0
        fi
        i=$((i + 1))
        sleep "$MODEL_PICKER_POLL"
    done
    PICKER_ELAPSED=$(ready_elapsed "$i" "$MODEL_PICKER_POLL")
    MODEL_ERROR="the footer still shows '${footer:-nothing}' after Enter, not '$target'"
    ready_note "$wt" "model=no want=$want reason=footer elapsed=${PICKER_ELAPSED}s session=$session"
    return 1
}

