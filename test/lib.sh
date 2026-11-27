#!/usr/bin/env bash
# Shared harness for the deviceless suites. Sourced by the runner, by every
# test area, and by gui-test.sh, so a fixture change is one edit.
#
# A temporary git repo stands in for the project; a fake tmux, a fake stty
# and a stub freebuff stand in for sessions, so no Freebuff, account slot,
# gh, network or phone is needed.

# shellcheck shell=bash
[ -n "${FB_TEST_LIB-}" ] && return 0
FB_TEST_LIB=1

set -euo pipefail
# An unguarded command that fails ends a suite under `set -e`. Say which one:
# without this a CI run stops with no FAIL line and only the last stderr write
# for company, which is what took a whole suite rerun to explain (#32).
trap 'rc=$?; printf "error: line %s exited %s\n" "${BASH_LINENO[0]}" "$rc" >&2' ERR

TEST_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd) || exit 1
ROOT=$(dirname -- "$TEST_DIR")
TOOL="$ROOT/spawn-freebuff-agent"

TMP=$(mktemp -d) || exit 1
REPO="$TMP/repo"
FAKE_DIR="$TMP/fake"
WT="$REPO/.worktrees/test-999"

_cleanup() {
    local rc=$?
    if [ -n "${TEST_CLEANUP_HOOK-}" ] && declare -F "$TEST_CLEANUP_HOOK" >/dev/null; then
        "$TEST_CLEANUP_HOOK" || true
    fi
    rm -rf "$TMP"
    return "$rc"
}
trap _cleanup EXIT

mkdir -p "$REPO" "$FAKE_DIR" "$TMP/bin"
git -C "$REPO" init -q
git -C "$REPO" config user.email test@example.invalid
git -C "$REPO" config user.name Test
git -C "$REPO" config commit.gpgsign false
printf 'hello\n' >"$REPO/README.md"
git -C "$REPO" add README.md
git -C "$REPO" commit -qm init
git -C "$REPO" branch -M main
# A remote gives the fixture a slug, which is what the GitHub state sync needs
# before it will touch anything.
git -C "$REPO" remote add origin https://github.com/owner/repo.git

total=0
failed=0

check() {
    total=$((total + 1))
    if "$@"; then
        return 0
    fi
    failed=$((failed + 1))
    # Name the area file and the line that failed, not just the command: with
    # the suite split over several files, `FAIL test 2 = 1` says nothing about
    # where to look.
    printf 'FAIL %s:%s %s\n' "$(basename -- "${BASH_SOURCE[1]}")" \
        "${BASH_LINENO[0]}" "$*" >&2
}

contains() {
    # contains <text> <needle>
    printf '%s' "$1" | grep -qF -- "$2"
}

json_ok() {
    # json_ok <text> -> 0 when it parses as JSON. Without python3, fall back to
    # the shape the emitters promise plus the absence of raw tab/CR bytes, so
    # the check still means something on a bare phone.
    local text=${1-}
    if command -v python3 >/dev/null 2>&1; then
        printf '%s' "$text" | python3 -m json.tool >/dev/null 2>&1
        return
    fi
    case "$text" in
        '['*']'|'{'*'}') ;;
        *) return 1 ;;
    esac
    ! printf '%s' "$text" | LC_ALL=C grep -q $'[\t\r]'
}

# ---- fake gh: records what the state sync asked for, answers nothing ----

: >"$TMP/gh.log"
export GH_LOG="$TMP/gh.log"
: >"$TMP/gh-labels"
export FAKE_GH_LABELS="$TMP/gh-labels"
cat >"$TMP/bin/gh" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GH_LOG:?}"
case " ${1:-} ${2:-} " in
    ' issue view ')
        # The label query answers what the fake issue currently shows, so a
        # test can prove the old status label is removed rather than assumed.
        case " $* " in
            *labels*) cat "${FAKE_GH_LABELS:-/dev/null}" 2>/dev/null || true ;;
            *) printf '[]' ;;
        esac
        ;;
esac
exit 0
FAKE
chmod +x "$TMP/bin/gh"
# GH_BIN so every area uses it whether or not $TMP/bin is on PATH.
export GH_BIN="$TMP/bin/gh"

# ---- fake tmux for lifecycle checks (#3, #4) ----

: >"$FAKE_DIR/tty"
: >"$FAKE_DIR/killed"
: >"$FAKE_DIR/escaped"
: >"$FAKE_DIR/sent"
cat >"$TMP/bin/tmux" <<'FAKE'
#!/usr/bin/env bash
d=${FAKE_TMUX_DIR:?}
case "${1:-}" in
    has-session)
        grep -qxF -- "${3:-}" "$d/session" 2>/dev/null
        ;;
    capture-pane)
        cat "$d/pane" 2>/dev/null || true
        ;;
    display-message)
        fmt="${!#}"
        case "$fmt" in
            *pane_tty*)
                # Opt-in: ready_after N makes the pane report no tty for N
                # checks, so a tmux that cannot name its pane tty is
                # simulated as a poll count instead of a real wait.
                if [ -f "$d/ready_after" ]; then
                    left=$(cat "$d/ready_after" 2>/dev/null || printf '0')
                    if [ "$left" -gt 0 ]; then
                        printf '%s\n' "$((left - 1))" >"$d/ready_after"
                        exit 0
                    fi
                    rm -f "$d/ready_after"
                fi
                printf '%s\n' "$d/tty"
                ;;
            *session_activity*) cat "$d/activity" 2>/dev/null || printf '0\n' ;;
            *) printf '0\n' ;;
        esac
        ;;
    send-keys)
        if [ "${!#}" = Escape ]; then
            printf '%s\n' "${3:-}" >>"$d/escaped"
            if [ -f "$d/pane_after_escape" ]; then
                mv "$d/pane_after_escape" "$d/pane"
            fi
        else
            # One tab-separated line per call, so a test can prove that a
            # literal text arrived as a single argument instead of being
            # split by a shell.
            line=''
            for arg in "$@"; do line+="$arg"$'\t'; done
            printf '%s\n' "$line" >>"$d/sent"
            # After Enter the pane shows what the TUI did with the brief. A
            # fixture file overrides it (a refusal, a swallowed Enter); by
            # default the send was accepted, so the pane becomes a turn in
            # flight, which is what start now requires before started=yes.
            if [ "${!#}" = C-m ]; then
                if [ -f "$d/pane_after_send" ]; then
                    mv "$d/pane_after_send" "$d/pane"
                elif [ -f "$d/turn_pane" ]; then
                    cp "$d/turn_pane" "$d/pane"
                fi
            fi
        fi
        ;;
    kill-session)
        printf '%s\n' "${3:-}" >>"$d/killed"
        if [ -f "$d/session" ]; then
            grep -vxF -- "${3:-}" "$d/session" >"$d/session.tmp" 2>/dev/null || true
            mv "$d/session.tmp" "$d/session"
        fi
        ;;
    new-session)
        # Opt-in: only a test that reaches the send path creates the ready
        # file, so a launch in a pane that cannot take input still fails fast
        # (wait_ready would otherwise poll for the whole window).
        if [ -f "$d/ready" ]; then
            prev=''
            for arg in "$@"; do
                if [ "$prev" = -s ]; then printf '%s\n' "$arg" >>"$d/session"; fi
                prev=$arg
            done
        fi
        ;;
    list-sessions)
        cat "$d/session" 2>/dev/null || true
        ;;
    *)
        exit 0
        ;;
esac
FAKE
chmod +x "$TMP/bin/tmux"
export FREEBUFF_TMUX="$TMP/bin/tmux"
export FAKE_TMUX_DIR="$FAKE_DIR"

# A fake stty reports raw mode, and a stub freebuff keeps the launch path
# honest on a runner without the real CLI. Areas that send put $TMP/bin on
# PATH. Opt-in: raw_after N reports canonical mode for N checks, so a cold
# launch that has a tty but has not reached raw input yet is simulated as a
# poll count instead of a real wait; the happy path stays raw.
cat >"$TMP/bin/stty" <<'FAKE'
#!/usr/bin/env bash
d=${FAKE_TMUX_DIR:?}
if [ -f "$d/raw_after" ]; then
    left=$(cat "$d/raw_after" 2>/dev/null || printf '0')
    if [ "$left" -gt 0 ]; then
        printf '%s\n' "$((left - 1))" >"$d/raw_after"
        printf '%s\n' 'speed 38400 baud; line = 0; icanon echo'
        exit 0
    fi
    rm -f "$d/raw_after"
fi
printf '%s\n' 'speed 38400 baud; line = 0; -icanon -echo'
FAKE
cat >"$TMP/bin/freebuff" <<'FAKE'
#!/usr/bin/env bash
exit 0
FAKE
chmod +x "$TMP/bin/stty" "$TMP/bin/freebuff"
# The send-path areas opt in to these; until then the real tools answer, so
# status input mode matches a launch that has not reached a pane.

fake_session() {
    printf '%s\n' "$2" >"$FAKE_DIR/pane"
    printf 'fb-%s\n' "$1" >"$FAKE_DIR/session"
    printf '%s\n' "${3:-$(date +%s)}" >"$FAKE_DIR/activity"
    : >"$FAKE_DIR/killed"
    : >"$FAKE_DIR/sent"
}

fake_clear() {
    rm -f "$FAKE_DIR/session"
    : >"$FAKE_DIR/killed"
    : >"$FAKE_DIR/sent"
}

fake_add_session() {
    # fake_add_session NAME: add a live fb-* session next to the fixture one
    printf 'fb-%s\n' "$1" >>"$FAKE_DIR/session"
}

launch_brief() {
    # launch_brief NAME ISSUE [extra...]: one start that reaches the send. The
    # caller puts $TMP/bin on PATH and opts in with : >"$FAKE_DIR/ready".
    # An accepted launch leaves the fake pane on a turn in flight, so a next
    # launch would never become ready. Reset only that leftover turn: a pane
    # a caller set on purpose (the concurrent-session overlay) is kept.
    if [ "$(cat "$FAKE_DIR/pane" 2>/dev/null)" = "$TURN_PANE" ]; then
        printf '%s\n' "$IDLE_PANE" >"$FAKE_DIR/pane"
    fi
    bash "$TOOL" --root "$REPO" start --issue "$2" --name "$1" \
        --branch "test/$1" --title T --url U ${3+"${@:3}"}
}

# Panes as captured from Freebuff 0.2.38.
IDLE_PANE='╭──────────────────╮
│  ▍Enter a coding task or / for commands
╰──────────────────╯
 DeepSeek V4.1 Flash • high · /tmp/x/proj · /model to change · Chat: New chat'
BUSY_PANE='thinking...                                      7s  ■ Esc
╭──────────────────╮
│  ▍Add to the current task (/ for commands)'
# A pane with no busy marker and no idle prompt: no rule can classify it, so
# it is `unknown` with evidence instead of the old working fallback.
NOMARKER_PANE='⎘ • 6s • △▽
╭──────────────────╮
│  ▍Add to the current task (/ for commands)'
REFUSED_PANE='Your concurrent-session limit across CLI and Desktop is reached.
Enter: take over  Esc: back to draft'
# The anti-automation refusal is a finished turn, not chrome: the sentence
# sits above the resting prompt, so a chrome-only check reads this as idle.
STRIKE_PANE='Freebuff did not send this message to the model. It breaks the usage policy (Scripted or automated use): it is the same message sent over and over, or automated account or site farming. It counts as strike 1 today. Strikes reset at midnight, when your daily hours refill.
╭──────────────────╮
│  ▍Enter a coding task or / for commands
╰──────────────────╯
 DeepSeek V4.1 Flash • high · /tmp/x/proj · /model to change · Chat: New chat'
# The account budget line is part of the same refusal vocabulary.
BUDGET_PANE='Your account budget for today is exhausted.
╭──────────────────╮
│  ▍Enter a coding task or / for commands
╰──────────────────╯
 DeepSeek V4.1 Flash • high · /tmp/x/proj · /model to change · Chat: New chat'
APPROVAL_PANE='Run command: git status
Allow once   Allow always   Deny'
# Captured from 0.2.38: the startup banner sits inside the 12-line window
# together with the resting prompt, so the prompt has to win.
BANNER_IDLE_PANE=' Can.t reach Freebuff.s servers. Retrying… Try another network.
╭──────────────────╮
│  ▍Enter a coding task or / for commands
╰──────────────────╯
 DeepSeek V4.1 Flash 10/17 • high · /tmp/x/proj · /model to change · Chat: New chat'
# A submitted brief: the composer is empty again, the turn is in flight and
# the chat title now names the task instead of `New chat`.
TURN_PANE='thinking...                                      7s  ■ Esc
╭──────────────────╮
│  ▍Add to the current task (/ for commands)
╰──────────────────╯
 DeepSeek V4.1 Flash • high · /tmp/x/proj · /model to change · Chat: Read .task.md'
# The swallowed Enter (#39), exactly as observed: the composer is empty again
# and the session rests at the idle prompt with the title untouched.
SWALLOWED_PANE='╭──────────────────╮
│  ▍Enter a coding task or / for commands
╰──────────────────╯
 DeepSeek V4.1 Flash • high · /tmp/x/proj · /model to change · Chat: New chat'
# An Enter that never arrived: the brief is still drawn in the input line.
TYPED_PANE='╭──────────────────╮
│  ▍Read the file .task.md in this directory and execute it…
╰──────────────────╯
 DeepSeek V4.1 Flash • high · /tmp/x/proj · /model to change · Chat: New chat'
# The client took the brief and named the chat, but the turn chrome has not
# been drawn yet: the changed title is the only proof the send was accepted.
TITLE_ONLY_PANE='╭──────────────────╮
│  ▍Enter a coding task or / for commands
╰──────────────────╯
 DeepSeek V4.1 Flash • high · /tmp/x/proj · /model to change · Chat: Read .task.md'
# Same banner with a turn in flight: no busy marker, mid-turn prompt.
BANNER_BUSY_PANE=' Can.t reach Freebuff.s servers. Retrying… Try another network.
⎘ • 6s • △▽
╭──────────────────╮
│  ▍Add to the current task (/ for commands)'
# Agent prose mentioning a permission must not outrank the resting prompt.
PROSE_AT_PROMPT_PANE='No permission was required for that deletion.
╭──────────────────╮
│  ▍Enter a coding task or / for commands
╰──────────────────╯
 DeepSeek V4.1 Flash • high · /tmp/x/proj · /model to change · Chat: New chat'

# The default outcome of an Enter: the brief was taken and a turn is running.
printf '%s\n' "$TURN_PANE" >"$FAKE_DIR/turn_pane"
