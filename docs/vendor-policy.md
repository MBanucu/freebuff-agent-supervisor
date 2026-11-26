# Vendor policy: scripted use

Freebuff polices scripted or automated use. Its filter refuses a message that
repeats one already sent — "It breaks the usage policy (Scripted or automated
use): it is the same message sent over and over" — and counts a strike against
the account; strikes reset at midnight with the daily hours. The refused
session is released, so the run produces nothing.

This tool drives an interactive client with a shell-backed account, several
sessions at a time, and types a brief into each. It can therefore generate
exactly the pattern that filter looks for. The mitigation below does not make
that automation permissible, and it does not override the vendor's decision:
it only stops the tool from tripping the filter by accident, which is a bug in
this repository, not a policy argument.

- **Unique by construction.** The stock brief names the session, branch,
  worktree and issue, so two issues never send the same bytes. There is no
  random filler: the text carries real content instead of looking less
  scripted.
- **A ledger of what was sent.** Each send is hashed into
  `.supervisor-briefs.jsonl` (last 20 kept) and an identical hash inside that
  window is refused locally, before any keystroke and before a worktree is
  created.
- **Jittered launches.** Under a multi-slot `--max-sessions`, sends are spaced
  by a random delay instead of arriving in one second.
- **A refused send is recorded, not retried.** `start` checks the pane before
  typing (the overlay gets no keys at all) and after the send. A refusal prints
  `refused=yes` with the sentence and exits non-zero; the sentence goes to
  `.supervisor.log`, and the hash is marked `"refused": true` in the same
  ledger. Refused hashes are kept past the 20-entry window and are never sent
  again.

If Freebuff refuses a send anyway, the strike is the vendor's decision and the
account's cost; this tool cannot undo it. Do not add randomised filler or
prompt churn to get around the filter — that is the behaviour the policy
targets, and a strike is the user's risk to accept before running several
agents.
