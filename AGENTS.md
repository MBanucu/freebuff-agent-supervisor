# AGENTS.md

Rules for anyone — agent or person — changing this repository. The file map,
recipes for adding a subcommand or a check, and the failure-reading guide live
in [`docs/development.md`](docs/development.md); read that before your first
change.

## The shipped artifact

- `spawn-freebuff-agent` is the whole tool: one bash file, no build step.
- Keep it one file. It must not `source` anything it does not ship, and it may
  not gain a runtime dependency, a JSON helper or `jq`.
- The tests are not shipped, so `test/lib.sh` may be shared by both suites.
- Runtime needs are bash, git, tmux and Freebuff. `python3` is optional and
  only for `gui --serve`; `gh` enriches output but must not be required.

## Checks

Run both suites before you commit:

```bash
./spawn-freebuff-agent-test.sh   # deviceless CLI suite
./gui-test.sh                    # gui server suite
```

- Each prints one `ok N checks` line and exits 0; a failure prints
  `FAIL <area>:<line> <command>`.
- The check counts must not drop. A pure move keeps the count identical; an
  issue that adds coverage says the new count in its PR. At the time of
  writing the baselines are `ok 517 checks` and `ok 107 gui checks`.
- `gui-test.sh` skips with exit 0 when `python3` or `curl` is missing. If it
  skipped for you, say so in the PR instead of reporting a gui pass.
- Add a check in the area file that owns the topic. Only add a new area file
  for a new topic, and then add it to the runner's list. See
  [`docs/development.md`](docs/development.md#how-to-add-a-check).

## Commits and pull requests

- Commit style: `type: sentence (#issue)`, for example
  `docs: add the contributor map (#86)`. Use a conventional type (`fix`,
  `feat`, `docs`, `test`, `refactor`) and one sentence.
- `main` only takes pull requests. Work on a branch, push it, open a PR; never
  push to `main`.
- Link the issue in the PR body and list what you actually ran.

## What not to delete

- Never delete a worktree or a branch. `stop`, autostop and `gc` only kill
  `fb-*` tmux sessions; the branch and `.worktrees/<name>` stay for review.
- Cleanup is the maintainer's explicit `git worktree remove` and
  `git branch -d`. `gc --prune-worktrees` prints them; the tool never runs
  them, and a `refused` launch is never offered for pruning.
- Do not commit generated state: `.task.md`, `.agent-result`,
  `local.properties`, `.worktrees/`, `.supervisor.log`,
  `.supervisor-briefs.jsonl` or `.supervisor-hours`.

## Fixtures

The fake tmux, fake stty, stub freebuff, captured pane fixtures and the
`check`/`contains`/`json_ok` helpers all live in `test/lib.sh`. Change a
fixture there once and both suites see it; `gui-test.sh` adds only its server
harness on top. Details and the pane-fixture policy are in
[`docs/development.md`](docs/development.md#fixtures-and-the-shared-harness).
