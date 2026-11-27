#!/usr/bin/env bash
# Spawn and inspect parallel Freebuff agents, one git worktree per agent.
#
# What this wraps:
#   1. create a git worktree and branch from a base;
#   2. write the task brief to .task.md in the worktree;
#   3. start Freebuff in a detached tmux session at 180x55 (the TUI does not
#      enter raw input mode in smaller panes);
#   4. wait until the TUI accepts input, then send the short "read .task.md"
#      prompt;
#   5. status/list/attach/stop/send against the live session;
#   6. optionally watch for the agent's .agent-result and stop the session.
#
# The agent is told to commit, push and open the PR. This tool never commits
# and never touches the main worktree.
#
# Map. The file is one unit (Install says copy it and `chmod +x`), so this is
# the index instead of a split: one `# ---- <area> ----` banner per area, in
# file order, naming the functions it owns. No line numbers: they rot.
#
#   argv and usage:
#     usage, die, note, is_num, is_duration, valid_name
#   tmux, freebuff, stty and git discovery:
#     repo_slug, tmux_bin, freebuff_bin, stty_bin, exclude_path,
#     ensure_excludes
#   the preflight:
#     preflight_termux, preflight_pkg, preflight_hint, preflight_run,
#     preflight_die, preflight
#   the wake lock:
#     wake_lock_state, wake_lock_acquire
#   state files and refusals:
#     result_key, result_state, state_is_terminal, refusal_recorded,
#     refusal_sentence, refusal_record, clear_refusal, refusal_is_hours,
#     hours_quota, hours_panel, hours_footer, hours_source, hours_age_label,
#     account_credentials_file, account_token, account_hours_div, account_read,
#     hours_read, refusal_notes
#   escaping and JSON:
#     json_str, json_nullable_str, json_nullable_num, html_escape,
#     json_unescape, json_scalar, state_class, action_form, stylesheet_file,
#     pr_json_array
#   state classification and evidence:
#     sha256_hex, normalise_window, first_match, evidence_field,
#     classify_chrome, freebuff_config_dir, turn_log_path, turn_log_read,
#     turn_log_evidence, turn_log_cursor, turn_log_poll, concord_file,
#     concord_validate, concord_task_record, concord_map_state,
#     concord_evidence, emit_evidence, classify_state, session_state,
#     session_activity, idle_seconds
#   the brief:
#     write_task, ready_polls, ready_elapsed, ready_note, wait_ready,
#     composer_line, chat_title, composer_cleared, turn_began,
#     await_submission, brief_hash, brief_ledger_file, brief_ledger_seen,
#     brief_ledger_trim, brief_ledger_record, brief_ledger_mark_refused,
#     refuse_sent_brief, compose_brief, brief_jitter_max
#   the model picker and the key it writes:
#     model_norm, picker_frame, picker_entries, picker_names, picker_selected,
#     picker_price, model_hours_cost, model_state, model_footer, model_resolve,
#     picker_wait, model_choose, model_settings_path, model_lock_dir,
#     model_key_value, model_key_snapshot, model_key_write, model_key_drop,
#     model_lock_acquire, model_lock_release, model_key_take, model_key_put_back
#   the issue mirror:
#     gh_state_color, gh_state
#   start:
#     start
#   status, list, sessions, hours and models:
#     print_explanation, launch_branch, worktree_branch, status, list_agents,
#     watcher_state, live_sessions, live_session_count, finished_live,
#     finished_live_names, sessions, hours, models
#   watch, autostop, notify, reap and gc:
#     reap, watch_run, watch, autostop, notify, gc
#   the GUI:
#     snapshot_html, gui
#   attach, send and stop:
#     attach, send, stop
#   the dispatch:
#     no functions: the --root peel, --help and the case over $cmd
set -euo pipefail

