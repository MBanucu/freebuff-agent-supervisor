# ---- the brief ----
# Composing it, waiting for a ready pane, proving the send, and the hash
# ledger that refuses to type a repeat.
write_task() {
    local file="$1" slug="${2:-}" issue="$3" title="$4" url="$5" branch="$6" base="$7"
    cat >"$file" <<EOF
# Task: issue #$issue — $title

Repo: ${slug:-this repository}. Branch: \`$branch\` (based on \`$base\`).
Issue: $url
Read it with: \`gh issue view $issue${slug:+ -R $slug}\`.

## Deliverable

Implement the issue end to end in this worktree. Follow the repository's
existing conventions. Add or update the tests the change needs. Run the
relevant checks and report exactly what was run.

## Constraints

- Work only in this worktree. Do not modify the main worktree or another
  worktree.
- Do not commit \`.task.md\`, \`.agent-result\` or \`local.properties\`.
- Do not touch unrelated files.
- If you need the phone, do not reboot or lock it; read-only adb checks only.
- If blocked, commit what works and open a draft PR explaining the blocker.

## Finish

Commit with a conventional message, push \`$branch\`, and open a PR against
\`$base\` with \`gh pr create\`. The PR body must link #$issue and list what
was tested. Report the PR URL, branch, commit and tests in your final message.

As your last action, write \`.agent-result\` in this worktree root. Use one
\`key=value\` per line, no JSON:

    state=done          # done, blocked or failed
    pr=<PR URL, or none>
    commit=<short sha, or none>
    tests=<one line: what you ran>

Use \`state=blocked\` when you opened a draft PR because of a blocker and
\`state=failed\` when the branch is not usable. Write the file even when
blocked, and do not commit it.
EOF
}

ready_polls() {
    # ready_polls TIMEOUT POLL -> poll intervals that fit in TIMEOUT, rounded
    # up, so the deadline follows --ready-timeout instead of a fixed count.
    awk -v t="$1" -v p="$2" 'BEGIN {
        n = t / p; c = int(n); if (n > c) c++; if (c < 1) c = 1
        printf "%d", c
    }'
}

ready_elapsed() {
    # ready_elapsed POLLS POLL -> seconds spent polling, with one decimal so a
    # sub-second interval is visible. awk is already used for the brief ledger.
    awk -v n="$1" -v p="$2" 'BEGIN { printf "%.1f", n * p }'
}

ready_note() {
    # ready_note WORKTREE MESSAGE -> a readiness line on stdout and in
    # .supervisor.log, so a slow launch is evidence instead of silence after
    # the terminal is gone.
    local wt="$1"
    shift
    note "$*"
    [ -d "$wt" ] || return 0
    printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >>"$wt/.supervisor.log"
}

wait_ready() {
    # wait_ready TMUX SESSION WORKTREE TIMEOUT POLL -> 0 ready, 2 refused,
    # 3 trust prompt, 1 did not become ready. A refusal is checked first: the
    # overlay never draws the resting prompt, and typing into it would take
    # over another live session instead of starting this one. The trust prompt
    # is next: it also never reaches the resting prompt, and it is the user's
    # decision to answer. The wait is a predicate with a deadline, not a fixed
    # sleep count: it re-checks every POLL seconds until TIMEOUT has passed, so
    # a warm pane returns on the first check and a cold launch gets the whole
    # --ready-timeout budget.
    #
    # "Not raw yet" is not the only way a check can fail. If tmux names no tty,
    # or stty cannot run on the tty it named, the predicate can never become
    # true, and waiting out the deadline only hides the fault. After
    # READY_FAILS consecutive such failures the wait returns with the reason
    # in READY_REASON and the evidence in READY_ELAPSED/READY_TTY/READY_STTY/
    # READY_ERROR. A cool-down is not a hard failure: a tty that reports
    # canonical mode, or a raw pane without the resting prompt, keeps polling.
    local tmux="$1" session="$2" wt="$3" timeout="$4" poll="$5"
    local polls i=0 tty pane stty out rc fails=0 no_tty=0
    polls=$(ready_polls "$timeout" "$poll")
    # Resolved once, before the first check, so the happy path pays no lookup.
    stty=$(stty_bin 2>/dev/null || true)
    READY_REASON=''
    READY_STTY=''
    READY_TTY=''
    READY_ERROR=''
    while :; do
        if ! "$tmux" has-session -t "$session" 2>/dev/null; then
            READY_ELAPSED=$(ready_elapsed "$i" "$poll")
            READY_REASON=no-session
            return 1
        fi
        tty=$("$tmux" display-message -p -t "$session" '#{pane_tty}' 2>/dev/null || true)
        pane=$("$tmux" capture-pane -p -t "$session" -S "-$REFUSAL_WINDOW" 2>/dev/null || true)
        if printf '%s\n' "$pane" | grep -qiE "$REFUSED_RE"; then
            READY_ELAPSED=$(ready_elapsed "$i" "$poll")
            return 2
        fi
        if printf '%s\n' "$pane" | grep -qF "$TRUST_PROMPT"; then
            # The prompt is open and nothing else will be drawn. Return on the
            # first check; start names the directory and both ways to proceed.
            READY_ELAPSED=$(ready_elapsed "$i" "$poll")
            return 3
        fi
        if [ -z "$tty" ]; then
            no_tty=$((no_tty + 1))
            fails=0
            if [ "$no_tty" -ge "$READY_FAILS" ]; then
                READY_ELAPSED=$(ready_elapsed "$i" "$poll")
                READY_REASON=no-tty
                return 1
            fi
        else
            no_tty=0
            # stdout and stderr share one capture: on failure stty writes the
            # error and nothing else, and on success the settings are what
            # the -icanon check needs. Newlines are flattened so one log line
            # stays one line.
            if [ -n "$stty" ]; then
                out=$("$stty" -a -F "$tty" 2>&1) && rc=0 || rc=$?
            else
                out='stty not found on PATH (set FREEBUFF_STTY)'
                rc=127
            fi
            if [ "$rc" -ne 0 ]; then
                fails=$((fails + 1))
                READY_STTY=${stty:-stty}
                READY_TTY=$tty
                READY_ERROR=${out//$'\n'/ }
                if [ "$fails" -ge "$READY_FAILS" ]; then
                    READY_ELAPSED=$(ready_elapsed "$i" "$poll")
                    READY_REASON=stty
                    return 1
                fi
            else
                fails=0
                if printf '%s' "$out" | grep -q -- '-icanon' &&
                    printf '%s' "$pane" | grep -q 'Enter a coding task'; then
                    READY_ELAPSED=$(ready_elapsed "$i" "$poll")
                    ready_note "$wt" "ready=yes elapsed=${READY_ELAPSED}s timeout=${timeout}s poll=${poll}s"
                    return 0
                fi
            fi
        fi
        i=$((i + 1))
        if [ "$i" -ge "$polls" ]; then
            READY_ELAPSED=$(ready_elapsed "$i" "$poll")
            READY_REASON=timeout
            return 1
        fi
        if [ $((i % READY_NOTE_POLLS)) -eq 0 ]; then
            ready_note "$wt" "waiting-for-ready=yes elapsed=$(ready_elapsed "$i" "$poll")s timeout=${timeout}s poll=${poll}s"
        fi
        sleep "$poll"
    done
}

composer_line() {
    # composer_line PANE -> the TUI's input line, the one carrying the `▍`
    # glyph. A brief that was never submitted is still drawn there; an empty
    # composer shows the resting or the mid-turn prompt instead.
    printf '%s\n' "$1" | grep -F '▍' | tail -n 1 || true
}

chat_title() {
    # chat_title PANE -> the `Chat: ...` label the chrome draws. A brief the
    # client accepted names the chat after the task instead of `New chat`.
    printf '%s\n' "$1" | sed -n 's/.*Chat: //p' | tail -n 1 || true
}

composer_cleared() {
    # composer_cleared PANE -> 0 when the input line is empty again. Both the
    # resting prompt and the mid-turn prompt are empty-composer chrome; the
    # typed brief still sitting in the line is not, whether the Enter was
    # swallowed or never arrived.
    local line
    line=$(composer_line "$1")
    case "$line" in
        *'Enter a coding task'*|*'Add to the current task'*) return 0 ;;
    esac
    return 1
}

turn_began() {
    # turn_began PANE -> 0 when a turn is in flight. The mid-turn composer
    # carries no busy marker but it is not a brief waiting for Enter either:
    # the README already treats `Add to the current task` as busy while a turn
    # is in flight, so it is proof that the input was submitted.
    local chrome
    chrome=$(printf '%s\n' "$1" | tail -n 12)
    if printf '%s\n' "$chrome" | grep -qiE "$BUSY_RE"; then
        return 0
    fi
    printf '%s\n' "$chrome" | grep -qF 'Add to the current task'
}

await_submission() {
    # await_submission TMUX SESSION BEFORE_TITLE TIMEOUT POLL ->
    # 0 submitted, 2 refused, 1 no proof inside TIMEOUT. The brief has already
    # been typed and Entered; this reads the pane until it can prove the send
    # was taken. Proof is the input line clearing plus either a turn in flight
    # or a changed chat title. A refusal is checked first, because its answer
    # arrives as a finished turn above the resting prompt. Nothing is retyped
    # here: a deadline that passes returns 1 and the caller reports sent=no.
    local tmux="$1" session="$2" before_title="$3" timeout="$4" poll="$5"
    local polls i=0 pane chrome title
    polls=$(ready_polls "$timeout" "$poll")
    SUBMIT_PROOF=''
    SUBMIT_ELAPSED=0.0
    while :; do
        pane=$("$tmux" capture-pane -p -t "$session" -S "-$REFUSAL_WINDOW" 2>/dev/null || true)
        if printf '%s\n' "$pane" | grep -qiE "$REFUSED_RE"; then
            SUBMIT_ELAPSED=$(ready_elapsed "$i" "$poll")
            return 2
        fi
        chrome=$(printf '%s\n' "$pane" | tail -n 12)
        if composer_cleared "$pane"; then
            if turn_began "$pane"; then
                SUBMIT_PROOF=turn-began
                SUBMIT_ELAPSED=$(ready_elapsed "$i" "$poll")
                return 0
            fi
            title=$(chat_title "$chrome")
            if [ -n "$title" ] && [ "$title" != "$before_title" ]; then
                SUBMIT_PROOF=chat-title
                SUBMIT_ELAPSED=$(ready_elapsed "$i" "$poll")
                return 0
            fi
        fi
        i=$((i + 1))
        if [ "$i" -ge "$polls" ]; then
            SUBMIT_ELAPSED=$(ready_elapsed "$i" "$poll")
            return 1
        fi
        sleep "$poll"
    done
}

brief_hash() {
    # brief_hash TEXT -> a stable digest of the text about to be typed.
    # sha256sum is coreutils, shasum ships with macOS and cksum is the POSIX
    # last resort; the ledger is only ever read by this same tool, so a
    # weaker digest on a bare phone is enough to notice a repeat.
    if command -v sha256sum >/dev/null 2>&1; then
        printf '%s' "${1-}" | sha256sum | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1; then
        printf '%s' "${1-}" | shasum -a 256 | cut -d' ' -f1
    else
        printf '%s' "${1-}" | cksum | tr ' ' '-'
    fi
}

brief_ledger_file() {
    printf '%s/%s' "$ROOT" "$BRIEF_LEDGER"
}

brief_ledger_seen() {
    # brief_ledger_seen HASH -> the last ledger line carrying that hash, empty
    # when the brief was not sent inside the retained window.
    local file
    file=$(brief_ledger_file)
    [ -f "$file" ] || return 0
    grep -F "\"hash\": \"$1\"" "$file" 2>/dev/null | tail -n 1 || true
}

brief_ledger_trim() {
    # Keep the last BRIEF_LEDGER_KEEP entries, plus every entry marked refused.
    # A refused brief is never resent, so its hash has to outlive the window
    # instead of ageing out and being typed again next week.
    local file tmp
    file=$(brief_ledger_file)
    [ -f "$file" ] || return 0
    tmp="$file.tmp.$$"
    awk -v keep="$BRIEF_LEDGER_KEEP" '
        { line[NR] = $0; if ($0 ~ /"refused": true/) keepit[NR] = 1 }
        END {
            first = NR - keep + 1
            if (first < 1) first = 1
            for (i = 1; i <= NR; i++) {
                if (keepit[i] || i >= first) print line[i]
            }
        }
    ' "$file" >"$tmp"
    mv "$tmp" "$file"
}

brief_ledger_record() {
    # brief_ledger_record HASH NAME BRANCH [REFUSED] -> one JSON line, then
    # trim. REFUSED marks the text as one the vendor rejected, which the
    # ledger keeps past the window.
    local file line refused=${4:-}
    file=$(brief_ledger_file)
    mkdir -p "$(dirname "$file")"
    if [ -n "$refused" ]; then
        line=$(printf '{"at": %s, "name": %s, "branch": %s, "hash": %s, "refused": true}' \
            "$(json_str "$(date -u '+%Y-%m-%dT%H:%M:%SZ')")" \
            "$(json_str "${2:-}")" "$(json_str "${3:-}")" "$(json_str "${1:-}")")
    else
        line=$(printf '{"at": %s, "name": %s, "branch": %s, "hash": %s}' \
            "$(json_str "$(date -u '+%Y-%m-%dT%H:%M:%SZ')")" \
            "$(json_str "${2:-}")" "$(json_str "${3:-}")" "$(json_str "${1:-}")")
    fi
    printf '%s\n' "$line" >>"$file"
    brief_ledger_trim
}

brief_ledger_mark_refused() {
    # brief_ledger_mark_refused HASH NAME BRANCH -> mark the send that the
    # vendor refused. This is the same ledger as #48, not a second one: the
    # hash that was typed is the hash that must never be typed again.
    local file hash=$1 name=${2:-} branch=${3:-} tmp
    file=$(brief_ledger_file)
    mkdir -p "$(dirname "$file")"
    if [ -f "$file" ] && grep -qF "\"hash\": \"$hash\"" "$file"; then
        tmp="$file.tmp.$$"
        awk -v h="\"hash\": \"$hash\"" '
            index($0, h) && index($0, "\"refused\": true") == 0 {
                sub(/\}$/, ", \"refused\": true}")
            }
            { print }
        ' "$file" >"$tmp"
        mv "$tmp" "$file"
    else
        brief_ledger_record "$hash" "$name" "$branch" refused
    fi
    brief_ledger_trim
}

refuse_sent_brief() {
    # refuse_sent_brief HASH -> die when that text was already sent recently
    # or was refused by the vendor at any time. This runs before the worktree
    # is created, so a refusal costs no worktree and no keystroke; the earlier
    # send is named so the caller can change the brief instead of retrying.
    local seen at prev
    seen=$(brief_ledger_seen "$1")
    [ -n "$seen" ] || return 0
    at=$(printf '%s' "$seen" | sed -n 's/.*"at": "\([^"]*\)".*/\1/p')
    prev=$(printf '%s' "$seen" | sed -n 's/.*"name": "\([^"]*\)".*/\1/p')
    if printf '%s' "$seen" | grep -q '"refused": true'; then
        die "start: refusing a brief Freebuff already refused: its text was sent to ${prev:-another session} at ${at:-an earlier run} (hash $1) and rejected as scripted or automated use. A refused brief is never resent, so nothing was sent and nothing was created. Give this session different text (a different issue, name or --prompt)."
    fi
    die "start: refusing a duplicate brief: its text was already sent to ${prev:-another session} at ${at:-an earlier run} (hash $1). Freebuff refuses a repeated identical message as scripted or automated use and counts a strike, so nothing was sent and nothing was created. Give this session a different brief, name or issue, or pass a different --prompt."
}

compose_brief() {
    # compose_brief NAME BRANCH WORKTREE ISSUE PROMPT -> the text typed into
    # the TUI. It names real content (session, branch, worktree, issue) so the
    # stock brief cannot repeat; PROMPT replaces it entirely, and is then the
    # caller's job to keep unique (the ledger catches it otherwise).
    local name=$1 branch=$2 wt=$3 issue=$4 prompt=${5:-}
    if [ -n "$prompt" ]; then
        printf '%s' "$prompt"
        return 0
    fi
    local text="$PROMPT Session $name, branch $branch, worktree $wt."
    [ -z "$issue" ] || text="$text Issue #$issue."
    printf '%s' "$text"
}

