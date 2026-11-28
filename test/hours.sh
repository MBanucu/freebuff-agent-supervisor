#!/usr/bin/env bash
# Area: the remaining hour budget read from a live pane (#106).

# shellcheck shell=bash
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

# A clean inventory: this area reads whichever fb-* session is live, so a
# leftover session from another area would decide the unnamed case.
fake_clear
rm -f "$FAKE_DIR/pane_after_send"

# ---- the welcome panel wins over the footer ----
fake_session test-hours "$HOURS_PANEL_PANE"
if out=$(bash "$TOOL" --root "$REPO" hours); then rc=0; else rc=$?; fi
check test "$rc" -eq 0
check contains "$out" 'hours=0/21'
check contains "$out" 'session=fb-test-hours'
check contains "$out" 'source=panel'
check grep -qE '^hours=0/21 session=fb-test-hours age=[0-9]+s source=panel$' <<<"$out"

# ---- the footer fraction next to the model is the fallback ----
fake_session test-hours "$BANNER_IDLE_PANE"
if out=$(bash "$TOOL" --root "$REPO" hours); then rc=0; else rc=$?; fi
check test "$rc" -eq 0
check contains "$out" 'hours=10/17'
check contains "$out" 'source=footer'

# ---- NAME picks that session, not just any live one ----
fake_add_session test-other
if out=$(bash "$TOOL" --root "$REPO" hours test-other); then rc=0; else rc=$?; fi
check test "$rc" -eq 0
check contains "$out" 'session=fb-test-other'
check contains "$out" 'hours=10/17'

# ---- an age is the time since the pane last changed, not a fixed zero ----
fake_session test-hours "$BANNER_IDLE_PANE" "$(($(date +%s) - 600))"
if out=$(bash "$TOOL" --root "$REPO" hours); then rc=0; else rc=$?; fi
check test "$rc" -eq 0
check grep -qE '^hours=10/17 session=fb-test-hours age=6[0-9][0-9]s source=footer$' <<<"$out"

# ---- a live pane that shows no fraction is unknown, never a guess ----
fake_session test-hours "$IDLE_PANE"
if out=$(bash "$TOOL" --root "$REPO" hours); then rc=0; else rc=$?; fi
check test "$rc" -eq 2
check contains "$out" 'hours=unknown'
check contains "$out" 'session=fb-test-hours'
check contains "$out" 'source=none'

# ---- no live session: unknown with exit 2, and no session field ----
fake_clear
if out=$(bash "$TOOL" --root "$REPO" hours); then rc=0; else rc=$?; fi
check test "$rc" -eq 2
check test "$out" = 'hours=unknown'

# A NAME naming a session that is not live is the same answer.
if out=$(bash "$TOOL" --root "$REPO" hours test-gone); then rc=0; else rc=$?; fi
check test "$rc" -eq 2
check test "$out" = 'hours=unknown'

# ---- --json is the same fields as one object ----
fake_session test-hours "$BANNER_IDLE_PANE"
if out=$(bash "$TOOL" --root "$REPO" hours --json); then rc=0; else rc=$?; fi
check test "$rc" -eq 0
check json_ok "$out"
check contains "$out" '"hours":"10/17"'
check contains "$out" '"session":"fb-test-hours"'
check contains "$out" '"source":"footer"'

# Without a live session the object carries nulls, not invented values.
fake_clear
if out=$(bash "$TOOL" --root "$REPO" hours --json); then rc=0; else rc=$?; fi
check test "$rc" -eq 2
check json_ok "$out"
check contains "$out" '"hours":null'
check contains "$out" '"session":null'
check contains "$out" '"source":null'

# ---- argument handling ----
if out=$(bash "$TOOL" --root "$REPO" hours --bogus 2>&1); then rc=0; else rc=$?; fi
check test "$rc" -eq 1
check contains "$out" 'hours: unsupported argument: --bogus'
if out=$(bash "$TOOL" --root "$REPO" hours a b 2>&1); then rc=0; else rc=$?; fi
check test "$rc" -eq 1
check contains "$out" 'hours: at most one NAME'

# ---- the pane object keeps the account fields, null when unfetched ----
fake_session test-hours "$BANNER_IDLE_PANE"
if out=$(bash "$TOOL" --root "$REPO" hours --json); then rc=0; else rc=$?; fi
check test "$rc" -eq 0
check contains "$out" '"remaining":null'
check contains "$out" '"limit":null'
check contains "$out" '"reset_at":null'

# ---- the account source (#124) ----
# The fake curl on PATH answers the API, and the token is read from the
# client's config root, which the harness points at $TMP.
mkdir -p "$FREEBUFF_CONFIG_DIR"
printf '{"default":{"authToken":"tok-abc","email":"dev@example.invalid"}}\n' \
    >"$FREEBUFF_CONFIG_DIR/credentials.json"
printf '%s\n' '{"freebucks":{"balance":25,"daily":{"limit":105,"spent":80,"remaining":25,"resetAt":"2026-11-27T23:00:00.000Z","resetTimeZone":"Europe/Berlin"},"wallet":{"balance":0,"monthlyBonus":0},"planId":null}}' \
    >"$FAKE_DIR/curl_body"
printf '200\n' >"$FAKE_DIR/curl_http"
printf '0\n' >"$FAKE_DIR/curl_status"
rm -f "$REPO/.supervisor-hours"
fake_clear
if out=$(PATH="$TMP/account-bin:$TMP/bin:$PATH" bash "$TOOL" --root "$REPO" hours --source account); then rc=0; else rc=$?; fi
check test "$rc" -eq 0
check test "$out" = 'hours=5/21 reset=2026-11-27T23:00:00Z session=- source=account'
check grep -qF 'Authorization: Bearer tok-abc' "$FAKE_DIR/curl_args"
check grep -qF 'https://freebuff.com/api/web/freebuff-session' "$FAKE_DIR/curl_args"
# The account reading is not a pane observation, so it does not enter the ledger.
check test ! -e "$REPO/.supervisor-hours"

if out=$(PATH="$TMP/account-bin:$TMP/bin:$PATH" bash "$TOOL" --root "$REPO" hours --source account --json); then rc=0; else rc=$?; fi
check test "$rc" -eq 0
check json_ok "$out"
check contains "$out" '"hours":"5/21"'
check contains "$out" '"session":null'
check contains "$out" '"remaining":25'
check contains "$out" '"limit":105'
check contains "$out" '"reset_at":"2026-11-27T23:00:00Z"'
check contains "$out" '"source":"account"'

# An empty remaining is exactly the refusal the pane shows as 0/21.
printf '%s\n' '{"freebucks":{"daily":{"limit":105,"spent":105,"remaining":0,"resetAt":"2026-11-28T23:00:00.000Z"}}}' \
    >"$FAKE_DIR/curl_body"
if out=$(PATH="$TMP/account-bin:$TMP/bin:$PATH" bash "$TOOL" --root "$REPO" hours --source account); then rc=0; else rc=$?; fi
check test "$rc" -eq 0
check test "$out" = 'hours=0/21 reset=2026-11-28T23:00:00Z session=- source=account'

# A rejected token is a named state, not an unknown figure, and a readable
# pane does not mask it.
: >"$FAKE_DIR/curl_body"
printf '401\n' >"$FAKE_DIR/curl_http"
printf '22\n' >"$FAKE_DIR/curl_status"
fake_session test-hours "$BANNER_IDLE_PANE"
if out=$(PATH="$TMP/account-bin:$TMP/bin:$PATH" bash "$TOOL" --root "$REPO" hours --source account); then rc=0; else rc=$?; fi
check test "$rc" -eq 2
check contains "$out" 'hours=unknown session=- source=account status=unauthorized'
check test -z "$(printf '%s\n' "$out" | grep -F 'source=footer' || true)"
check contains "$out" 'hint=log in again'

if out=$(PATH="$TMP/account-bin:$TMP/bin:$PATH" bash "$TOOL" --root "$REPO" hours --source account --json); then rc=0; else rc=$?; fi
check test "$rc" -eq 2
check json_ok "$out"
check contains "$out" '"status":"unauthorized"'
check contains "$out" '"source":"account"'
check contains "$out" '"remaining":null'

# A file with no default.authToken is said so and the pane is read instead,
# and no request is made at all.
printf '0\n' >"$FAKE_DIR/curl_status"
printf '200\n' >"$FAKE_DIR/curl_http"
printf '{"default":{"email":"dev@example.invalid"}}\n' \
    >"$FREEBUFF_CONFIG_DIR/credentials.json"
: >"$FAKE_DIR/curl_args"
fake_session test-hours "$BANNER_IDLE_PANE"
if out=$(PATH="$TMP/account-bin:$TMP/bin:$PATH" bash "$TOOL" --root "$REPO" hours --source account); then rc=0; else rc=$?; fi
check test "$rc" -eq 0
check contains "$out" 'account=unconfigured'
check contains "$out" 'hours=10/17'
check contains "$out" 'source=footer'
check test -z "$(cat "$FAKE_DIR/curl_args")"

# A credentials path that is not a readable file is the same answer, and no
# live session leaves the budget unknown with the reason beside it.
rm -f "$FREEBUFF_CONFIG_DIR/credentials.json"
mkdir -p "$FREEBUFF_CONFIG_DIR/credentials.json"
fake_clear
if out=$(PATH="$TMP/account-bin:$TMP/bin:$PATH" bash "$TOOL" --root "$REPO" hours --source account); then rc=0; else rc=$?; fi
check test "$rc" -eq 2
check test "$out" = $'account=unconfigured\nhours=unknown'
check test -z "$(cat "$FAKE_DIR/curl_args")"
rmdir "$FREEBUFF_CONFIG_DIR/credentials.json"

# ---- start refuses an hours-empty launch before it spends a slot ----
printf '{"default":{"authToken":"tok-abc"}}\n' \
    >"$FREEBUFF_CONFIG_DIR/credentials.json"
printf '%s\n' '{"freebucks":{"daily":{"limit":105,"spent":105,"remaining":0,"resetAt":"2026-11-28T23:00:00.000Z"}}}' \
    >"$FAKE_DIR/curl_body"
fake_clear
if out=$(PATH="$TMP/account-bin:$TMP/bin:$PATH" bash "$TOOL" --root "$REPO" start --issue 1240 \
    --name test-empty --branch test/empty --title T --url U 2>&1); then rc=0; else rc=$?; fi
check test "$rc" -eq 1
check contains "$out" 'refused=hours'
check contains "$out" 'hours=0/21'
check contains "$out" 'reset=2026-11-28T23:00:00Z'
check contains "$out" 'nothing was created'
check test ! -e "$REPO/.worktrees/test-empty"
check test -z "$(cat "$FAKE_DIR/launch")"

# --no-start launches nothing, so an empty account must not refuse it.
if out=$(PATH="$TMP/account-bin:$TMP/bin:$PATH" bash "$TOOL" --root "$REPO" start --issue 1241 \
    --name test-empty-nostart --branch test/empty-nostart --title T --url U \
    --no-start --no-gh 2>&1); then rc=0; else rc=$?; fi
check test "$rc" -eq 0
check contains "$out" "created=$REPO/.worktrees/test-empty-nostart"
check test -z "$(printf '%s\n' "$out" | grep -F 'refused=hours' || true)"

# --model skips the pre-flight: a free model spends no hours and the picker
# price is the only place that is known.
if out=$(PATH="$TMP/account-bin:$TMP/bin:$PATH" bash "$TOOL" --root "$REPO" start --issue 1242 \
    --name test-empty-model --branch test/empty-model --title T --url U \
    --model fast --ready-timeout 1 2>&1); then rc=0; else rc=$?; fi
check test -z "$(printf '%s\n' "$out" | grep -F 'refused=hours' || true)"
check test -d "$REPO/.worktrees/test-empty-model"
