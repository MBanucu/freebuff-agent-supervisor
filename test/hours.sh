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
