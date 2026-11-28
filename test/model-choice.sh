#!/usr/bin/env bash
# Area: the model picker (#125). `start --model` chooses the model before the
# brief is typed, so a launch cannot quietly land on a model whose hour costs
# two. The fake tmux answers /model with the captured picker, moves the `›`
# marker on an arrow key and shows the pane after the choice; every check
# reads what start did with those keys.

# shellcheck shell=bash
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

PATH="$TMP/bin:$PATH"
export PATH
export FREEBUFF_BIN="$TMP/bin/freebuff"
rm -f "$FAKE_DIR/ready_after" "$FAKE_DIR/raw_after" "$FAKE_DIR/pane_after_send" \
    "$FAKE_DIR/fast_sleep" "$FAKE_DIR/picker_open" "$FAKE_DIR/picker_pane" \
    "$FAKE_DIR/pane_after_model" "$FAKE_DIR/last_text"
: >"$FAKE_DIR/ready"

# The real sleeps in this area would only pay for polls: a picker that opens
# on the first check and a walk of a few keys are both counted, not timed.
REAL_SLEEP=$(command -v sleep)
cat >"$TMP/bin/sleep" <<FAKE
#!/usr/bin/env bash
if [ -f "\${FAKE_TMUX_DIR:?}/fast_sleep" ]; then exit 0; fi
exec "$REAL_SLEEP" "\$@"
FAKE
chmod +x "$TMP/bin/sleep"
: >"$FAKE_DIR/fast_sleep"

picker_on() {
    printf '%s\n' "$MODEL_PICKER_PANE" >"$FAKE_DIR/picker_pane"
    printf '%s\n' "$MODEL_AFTER_PANE" >"$FAKE_DIR/pane_after_model"
}

picker_off() {
    rm -f "$FAKE_DIR/picker_pane" "$FAKE_DIR/pane_after_model" \
        "$FAKE_DIR/picker_open" "$FAKE_DIR/last_text"
}

picker_select() {
    # picker_select NAME: draw the picker with the `›` marker on NAME, so a
    # check can make the walk start anywhere in the list.
    printf '%s\n' "$MODEL_PICKER_PANE" | awk -v want="$1" '
        /│/ && /•/ {
            name = $0
            sub(/^.*│ *›? */, "", name)
            sub(/ *•.*$/, "", name)
            gsub(/^ +| +$/, "", name)
            sub(/│ › /, "│   ")
            if (name == want) sub(/│   /, "│ › ")
        }
        { print }' >"$FAKE_DIR/picker_pane"
}

fresh() {
    # fresh: one launch from the idle pane with nothing recorded
    fake_clear
    printf '%s\n' "$IDLE_PANE" >"$FAKE_DIR/pane"
    : >"$FAKE_DIR/sent"
    : >"$FAKE_DIR/killed"
}

brief_not_sent() {
    ! grep -qF 'Read the file .task.md' "$FAKE_DIR/sent" 2>/dev/null
}

# ---- the flag itself ----

out=$(bash "$TOOL" --root "$REPO" start --issue 1101 --name test-model-dry \
    --branch test/model-dry --title T --url U --model fast --dry-run)
check contains "$out" 'model=fast'
check test ! -e "$REPO/.worktrees/test-model-dry"
check contains "$(bash "$TOOL" --help 2>&1)" '--model NAME'

if bash "$TOOL" --root "$REPO" start --issue 1101 --name test-model-empty \
    --branch test/model-empty --title T --url U --model '' --dry-run \
    >"$TMP/start.out" 2>&1; then rc=0; else rc=$?; fi
check test "$rc" -eq 1
check contains "$(cat "$TMP/start.out")" '--model must name a model'
check test ! -e "$REPO/.worktrees/test-model-empty"

# --no-start launches no session, so there is nothing to switch; saying so
# beats a worktree that looks as if a model were already chosen.
out=$(bash "$TOOL" --root "$REPO" start --issue 1102 --name test-model-nostart \
    --branch test/model-nostart --title T --url U --model fast --no-start)
check contains "$out" 'model=fast applied=no'
check test -d "$REPO/.worktrees/test-model-nostart"

# ---- a model the picker prices at no hours ----

picker_on
fresh
if bash "$TOOL" --root "$REPO" start --issue 1103 --name test-model-fast \
    --branch test/model-fast --title T --url U --model fast \
    >"$TMP/start.out" 2>&1; then rc=0; else rc=$?; fi
check test "$rc" -eq 0
out=$(cat "$TMP/start.out")
check contains "$out" 'model=DeepSeek V4.1 Flash Fast price=free'
check contains "$out" 'sent=yes'
check contains "$out" 'started=yes'
check grep -qF '/model' "$FAKE_DIR/sent"
check contains "$(cat "$REPO/.worktrees/test-model-fast/.supervisor.log")" \
    'model=DeepSeek V4.1 Flash Fast price=free'
# Choosing a model is a step before the brief, not a replacement for it.
check grep -qF 'Read the file .task.md' "$FAKE_DIR/sent"

# ---- a model the picker prices at two hours ----

fresh
if bash "$TOOL" --root "$REPO" start --issue 1104 --name test-model-two \
    --branch test/model-two --title T --url U --model 'DeepSeek V4.1 Flash' \
    >"$TMP/start.out" 2>&1; then rc=0; else rc=$?; fi
check test "$rc" -eq 0
check contains "$(cat "$TMP/start.out")" 'model=DeepSeek V4.1 Flash price=2x'
# An exact name wins over the longer name that contains it, and the marker
# started on the first entry, so reaching the second took one Down.
check grep -q 'Down' "$FAKE_DIR/sent"

# ---- the walk follows the marker and reverses at an end ----

picker_select 'GPT-6 Luna'
fresh
if bash "$TOOL" --root "$REPO" start --issue 1105 --name test-model-up \
    --branch test/model-up --title T --url U --model fast \
    >"$TMP/start.out" 2>&1; then rc=0; else rc=$?; fi
check test "$rc" -eq 0
check contains "$(cat "$TMP/start.out")" 'model=DeepSeek V4.1 Flash Fast price=free'
check grep -q 'Up' "$FAKE_DIR/sent"

# ---- a name that is ambiguous or unknown sends no brief ----

picker_on
fresh
if bash "$TOOL" --root "$REPO" start --issue 1106 --name test-model-ambig \
    --branch test/model-ambig --title T --url U --model flash \
    >"$TMP/start.out" 2>&1; then rc=0; else rc=$?; fi
check test "$rc" -eq 1
out=$(cat "$TMP/start.out")
check contains "$out" 'matches 2 models'
check contains "$out" 'model_want=flash'
check contains "$out" 'sent=no'
check test -d "$REPO/.worktrees/test-model-ambig"
check grep -qxF 'fb-test-model-ambig' "$FAKE_DIR/killed"
check contains "$(cat "$REPO/.worktrees/test-model-ambig/.supervisor.log")" \
    'model=no want=flash reason=resolve'
check brief_not_sent

fresh
if bash "$TOOL" --root "$REPO" start --issue 1107 --name test-model-none \
    --branch test/model-none --title T --url U --model gpt-9 \
    >"$TMP/start.out" 2>&1; then rc=0; else rc=$?; fi
check test "$rc" -eq 1
out=$(cat "$TMP/start.out")
check contains "$out" "no model matches 'gpt-9'"
# The error lists what the picker did offer, so a typo is fixable from it.
check contains "$out" 'DeepSeek V4.1 Flash Fast'
check brief_not_sent

# ---- a picker that never opens stops the launch ----

picker_off
fresh
if bash "$TOOL" --root "$REPO" start --issue 1108 --name test-model-nopicker \
    --branch test/model-nopicker --title T --url U --model fast \
    >"$TMP/start.out" 2>&1; then rc=0; else rc=$?; fi
check test "$rc" -eq 1
check contains "$(cat "$TMP/start.out")" '/model did not open the picker'
check grep -qxF 'fb-test-model-nopicker' "$FAKE_DIR/killed"
check contains "$(cat "$REPO/.worktrees/test-model-nopicker/.supervisor.log")" \
    'model=no want=fast reason=picker-timeout'
check brief_not_sent

# ---- a model below the fold is reachable ----

# The frame draws one page, so the name is absent from it: the search has to
# scroll the list before it can say so, and then walk the marker onto it.
picker_on
printf '%s\n' "$MODEL_PICKER_SCROLLED_PANE" >"$FAKE_DIR/picker_next_pane"
fresh
if bash "$TOOL" --root "$REPO" start --issue 1109 --name test-model-scroll \
    --branch test/model-scroll --title T --url U --model gpt-5.5 \
    >"$TMP/start.out" 2>&1; then rc=0; else rc=$?; fi
check test "$rc" -eq 0
out=$(cat "$TMP/start.out")
check contains "$out" 'model=GPT-5.5 price=daily'
check contains "$out" 'sent=yes'
rm -f "$FAKE_DIR/picker_next_pane"

# ---- models: the list, from the picker the client already has ----

check contains "$(bash "$TOOL" --help 2>&1)" 'models [NAME]'
picker_on
fake_session test-999 "$IDLE_PANE"
rm -f "$FAKE_DIR/picker_open" "$FAKE_DIR/picker_next_pane"
printf '%s\n' "$IDLE_PANE" >"$FAKE_DIR/pane_after_escape"
if bash "$TOOL" --root "$REPO" models >"$TMP/models.out" 2>&1; then rc=0; else rc=$?; fi
check test "$rc" -eq 0
out=$(cat "$TMP/models.out")
check contains "$out" 'model=DeepSeek V4.1 Flash Fast hours=free'
check contains "$out" 'model=DeepSeek V4.1 Flash hours=2x'
check contains "$out" 'models=3 session=fb-test-999'
# The picker is closed again and the session is left standing.
check grep -qxF 'fb-test-999' "$FAKE_DIR/escaped"
check grep -qxF 'fb-test-999' "$FAKE_DIR/session"
check contains "$(cat "$FAKE_DIR/pane")" 'Enter a coding task'

printf '%s\n' "$IDLE_PANE" >"$FAKE_DIR/pane_after_escape"
if bash "$TOOL" --root "$REPO" models test-999 --json \
    >"$TMP/models.json" 2>&1; then rc=0; else rc=$?; fi
check test "$rc" -eq 0
check json_ok "$(cat "$TMP/models.json")"
check contains "$(cat "$TMP/models.json")" '"count": 3'
check contains "$(cat "$TMP/models.json")" '"hours": "free"'
check contains "$(cat "$TMP/models.json")" '"price": "2x · May use data for AI training"'

# --free is the shortlist a launch picks from when hours are short: only the
# entries whose price line carries no hour multiplier (#136).
printf '%s\n' "$IDLE_PANE" >"$FAKE_DIR/pane_after_escape"
if bash "$TOOL" --root "$REPO" models test-999 --free >"$TMP/models.out" 2>&1; then rc=0; else rc=$?; fi
check test "$rc" -eq 0
out=$(cat "$TMP/models.out")
check contains "$out" 'model=DeepSeek V4.1 Flash Fast hours=free'
check test -z "$(printf '%s\n' "$out" | grep 'hours=2x' || true)"
check test -z "$(printf '%s\n' "$out" | grep 'hours=paid' || true)"
check contains "$out" 'models=1 session=fb-test-999'
check contains "$(bash "$TOOL" --help 2>&1)" '--free'

# A turn in flight, and a session with no picker to read, get no keys at all.
fake_session test-999 "$BUSY_PANE"
if bash "$TOOL" --root "$REPO" models >"$TMP/models.out" 2>&1; then rc=0; else rc=$?; fi
check test "$rc" -eq 1
check contains "$(cat "$TMP/models.out")" 'is working'
check test ! -s "$FAKE_DIR/sent"

fake_clear
if bash "$TOOL" --root "$REPO" models >"$TMP/models.out" 2>&1; then rc=0; else rc=$?; fi
check test "$rc" -eq 1
check contains "$(cat "$TMP/models.out")" 'no live fb-* session'
