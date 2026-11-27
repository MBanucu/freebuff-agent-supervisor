# Deeper integration with Freebuff

What the installed Freebuff client actually exposes for MCP, hooks and
completion notifications, and what this tool should build on it.

Roadmap only: nothing in this document is implemented. Child issues are at the
end.

- **Issue:** [#64](https://github.com/MBanucu/freebuff-agent-supervisor/issues/64)
- **Explored:** 2026-11-26
- **Client:** Freebuff 0.2.38 (`linux-x64`)
- **Method:** read-only. `freebuff --help`, `freebuff --version`, the installed
  bundle at `~/.config/manicode/freebuff` (an ELF file with the Bun-compiled
  source inside it), the config directory, and the per-chat files this machine
  already has on disk. No session was started, no file in the client's tree was
  written, and Freebuff itself was not patched or wrapped.

Every claim below is marked with the evidence that supports it: a flag, a file
path, a string in the bundle, or observed content. Where the evidence is a
vendor document rather than the build, it says so.

## 1. What is installed

`freebuff` on `PATH` is a symlink to `~/.local/lib/node_modules/freebuff/index.js`,
an npm wrapper. The wrapper downloads and runs a separate native binary.

| Thing | Value | Evidence |
| --- | --- | --- |
| `freebuff --version` | `0.2.38` | `freebuff --version` |
| npm wrapper version | `0.2.36` | `~/.local/lib/node_modules/freebuff/package.json` |
| native binary | `~/.config/manicode/freebuff`, 138 MB ELF | `readlink -f`, `file` |
| binary version record | `{"version":"0.2.38","target":"linux-x64"}` | `~/.config/manicode/freebuff-metadata.json` |
| version compiled in | `CODEBUFF_CLI_VERSION:"0.2.38"` | string in the bundle |
| config dir | `~/.config/manicode` | bundle: `yD()` returns `join(homedir(), ".config", "manicode")` |

The wrapper and the binary disagree on the version because the wrapper
self-updates the binary. Anything that reports "the version" should read
`freebuff --version`, not `package.json`.

`FREEBUFF_CONFIG_DIR` moves the config dir, and a relative value is rejected:

```
FREEBUFF_CONFIG_DIR must be an absolute path so CLI settings cannot be written
relative to the current project.
```

The rejection is in the bundle, in the same function that computes the default.
This matters for this tool: `credentials.json`, `settings.json`,
`trusted-agent-dirs.json` and the chat history all live under that one
directory, so a per-session `FREEBUFF_CONFIG_DIR` would also be a per-session
*login*. That rules out using it to isolate sessions.

## 2. The flag surface: what `--help` really offers

The whole of `freebuff --help` on 0.2.38:

```
Usage: freebuff [options] [command]

Freebuff - Free AI coding assistant

Arguments:
  command                       Command to run: login, or doctor to check this
                                computer for common problems (choices: "login",
                                "doctor")

Options:
  -v, --version                 Print the CLI version
  --continue [conversation-id]  Continue from a previous conversation
                                (optionally specify a conversation id)
  --cwd <directory>             Set the working directory (default: current
                                directory)
  --trust-agents                Load this repository's .agents files and
                                mcp.json without asking (for CI)
  -h, --help                    Show this help message
```

That is the complete commander definition, not a summary: the bundle builds the
Freebuff command in one expression and it ends at `helpOption`. There is no
hidden flag. In particular there is no `--json`, no `--notify`, no `--hook`, no
`--acp`, and no initial-prompt argument.

The sibling Codebuff CLI is built by the same function from the same binary and
*does* take one:

```
.option("--agent <agent-id>", ...).option("--clear-logs", ...)
.option("--lite", ...).option("--max", ...).option("--plan", ...)
.argument("[prompt...]", "Initial prompt to send to the agent")
```

Freebuff's branch omits `[prompt...]`, `--agent`, `--lite`, `--max` and
`--plan`. The omission is a product decision in code, not a missing feature that
a flag would turn on. This is the same conclusion the README already reaches
from the docs; it now has the code behind it.

## 3. Configuration: `settings.json` and what it does not contain

The settings reader is an explicit key-by-key copy, not a passthrough schema.
Unknown keys are dropped on read. The complete set it accepts:

`mode`, `adsEnabled`, `freebuffModel`, `freebuffModelDefaultMigration`,
`freebuffReasoningEfforts`, `freebuffModelKey`, `freebuffCatalogReasoningEfforts`,
`byokConnection`, `byokReasoningEffort`, `alwaysUseALaCarte`,
`fallbackToALaCarte`, `hasSubmittedFirstPrompt`, `freebucksIntroSeenAt`,
`displayAds`, `displayAdSplashHiddenOn`.

This machine's file is the subset in use:

```json
{
  "mode": "DEFAULT",
  "adsEnabled": true,
  "freebuffModelDefaultMigration": "glm-5.3-flash-2026-09-05",
  "freebuffModelKey": "m-8db1ccbba6",
  "hasSubmittedFirstPrompt": true
}
```

There is no `hooks`, no `notifications`, no `mcpServers`, no `onExit` and no
`command` key. A key invented here is silently discarded, so "add a setting and
see" is not an experiment worth running.

The other files in the config directory, and what each is:

| File | What it is |
| --- | --- |
| `settings.json` | the 15 keys above |
| `credentials.json` | login token (`0600`) |
| `device-key.json` | device key (`0600`) |
| `trusted-agent-dirs.json` | trusted `.agents` directories, by absolute path |
| `freebuff-metadata.json` | the binary's version and target |
| `freebuff-live-<sha256>.json` | one lease per live session (see §5) |
| `message-history.json` | input history |
| `projects/<name>/chats/<id>/` | one directory per conversation |

## 4. MCP: Freebuff is a client, not a host

This is the headline finding, and it is the opposite of what #66 assumes.

### It consumes MCP servers

The bundle has a full MCP client: `common/src/mcp/client.ts`,
`common/src/mcp/list-tools.ts`, `common/src/mcp/server-url.ts`,
`common/src/mcp/content-mapping.ts`, `packages/agent-runtime/src/mcp.ts`,
`sdk/src/agents/load-mcp-config.ts`. The file format is a zod schema:

```ts
export type MCPConfig =
  | { type?: 'stdio'; command: string; args?: string[]; env?: Record<string, string> }
  | { type?: 'http' | 'sse'; url: string; params?: Record<string, string>; headers?: Record<string, string> }
```

and the file itself:

```ts
mcpFileSchema = z.object({ mcpServers: z.record(z.string(), mcpConfigSchema).default(() => ({})) })
MCP_CONFIG_FILE_NAME = "mcp.json"
```

`mcpServers` is the standard Claude Code / Cursor shape, so an existing config
usually ports over unchanged.

### Where it looks

`mcp.json` is read from the same directories as the agent files:

```ts
Ix = () => [ join(process.cwd(), ".agents"),
             join(process.cwd(), "..", ".agents"),
             homeAgentsDir ]
```

so `.agents/mcp.json` in the working directory, in its parent, and in
`~/.agents/mcp.json`, merged in that order with **later winning** — a home
entry overrides the repository's. `$VAR` in an `env` block is resolved from the
CLI's own environment.

### The trust gate

A directory holding an `mcp.json` (or an executable agent file) is *untrusted*
until recorded, because loading it runs repository-supplied code. The gate:

- trusted store: `<configDir>/trusted-agent-dirs.json`, keyed by realpath, value
  `{"trustedAt": "<iso>"}`. This machine has one entry,
  `"/home/michi/MEGA/.agents"`.
- interactive launch (stdin and stdout are TTYs): a plain-terminal
  `Load and run these? [y/N]` prompt **before the TUI mounts**.
- non-interactive: skipped, with
  `Not loading agents or mcp.json from <dir>: it has not been trusted and this is
  not an interactive terminal.`
- the escape hatch is `--trust-agents`, or the environment variable
  `CODEBUFF_TRUST_AGENT_DIRS=1` (accepted values `1`, `true`, `yes`).
- `~/.agents` is the user's own and never prompts.

Note the variable name: `CODEBUFF_TRUST_AGENT_DIRS`, Codebuff-prefixed, even in
the Freebuff build. An operator who guesses `FREEBUFF_TRUST_AGENT_DIRS` gets
silently nothing.

### Consequence for this tool's worktrees

`start` runs Freebuff in `.worktrees/<name>`. The parent lookup is then
`.worktrees/.agents`, **not** the repository root's `.agents`. So:

- a `.agents/mcp.json` committed at the repository root is *not* seen by an
  agent running in a worktree;
- `~/.agents/mcp.json` *is* seen, by every worktree;
- if a worktree does get its own `.agents/` (the only way to give one session
  extra tools), the launch stops at the trust prompt. Under tmux stdin is a TTY,
  so the prompt is real. #76 makes `start` detect it, name the directory and
  both ways to proceed, and fail at once instead of waiting out
  `--ready-timeout`; `start --trust-agents` is the explicit opt-in that
  forwards the vendor flag. The default launch never pre-answers the gate.

No worktree here has `.agents/` yet, so the prompt only appears once a worktree
is given MCP tools. `--trust-agents` is available for that change; it is not a
default, because it runs repository-supplied code with the user's permissions.

### There is no `/mcp` command

The command registry in the bundle is built from `{name:"..."}` entries. The
complete set of names relevant to the TUI:

`help`, `diagnostics`, `dashboard`, `usage`, `model`, `reasoning`, `plan`,
`review`, `compact`, `todo`, `queue`, `new`, `history`, `copy`, `export`,
`bash`, `interview`, `byok`, `theme:toggle`, `deals`, `ads:*`, `feedback`,
`end-session`, `logout`, `exit`, `init`, `image`, `publish`.

No `mcp` entry. There is no way to list connected servers, their tools, or a
load error from inside the TUI. The vendor docs' slash-command table agrees on
the absence and disagrees on three others (below).

### It is not a host

No MCP server transport is present: `StdioServerTransport`, `SSEServerTransport`
and `StreamableHTTPServerTransport` all occur zero times. The MCP SDK's
`server/types.js` and `server/zod-compat.js` are bundled, but the only server in
the product is the built-in browser tool's (its prompt refers to "the MCP server
resolves each uid to the actual DOM element"). No flag, setting or config starts
a server that another client could connect to.

### Docs versus this build

The vendor docs (`docs.freebuff.page/mcp-servers`) describe two agent tools,
`search_mcp_tools` and `call_mcp_tool`. Neither string exists in the 0.2.38
bundle — the client injects a server's tools directly into the tool list
instead. So the docs describe a newer design than this build ships. Do not plan
against tool names from the docs without checking the bundle.

The docs' CLI page also says `/init`, `/image` and `/publish` are "deliberately
absent from this registry". This build registers all three. Treat that table as
approximate.

### How to check that a worktree loaded its servers

The loader logs at debug level, and the per-chat log runs at level `debug`:

```
[agents] Loaded MCP servers from mcp.json   { mcpServers: [...], source: "<path>" }
Failed to load MCP config from .agents directories   { error }
```

So `grep -F 'Loaded MCP servers' <chatdir>/log.jsonl` is a real verification
step, and the failure line is a real diagnosis. Nothing in the TUI shows either.

## 5. Hooks and events

### No hook surface exists

- `settings.json` has no hook key (§3).
- There is no `.agents/hooks.json`, `hooks` file name or `hooks` schema in the
  bundle.
- The one hook-shaped tool, `run_file_change_hooks`, is described as
  *"Trigger client-configured file change hooks… The client will run only the
  hooks whose filePattern matches the provided files."* That is an SDK surface
  for an embedder (Desktop) that owns a hook registry. The CLI never builds the
  `{hookName}` objects the tool returns — `hookName` appears exactly once in the
  bundle, in the tool's output schema. It is not implemented here.
- Nothing in the TUI exposes an event: no `onExit` option, no user callback, no
  config file with a command to run.

The only hook-like mechanism in the product is the *internal* event pipeline
(`sdk-event-handlers.ts`, `stream-state.ts`, `use-event.ts`), which is not
reachable from outside the process.

### But three files are written, and they carry the events

This is the useful part: the client already writes structured state to disk on
every turn.

**`<config>/projects/<project>/chats/<id>/log.jsonl`** — a pino JSONL log,
always written, at level `debug`. Observed across the 107 chat directories on
this machine:

| Message | Count | Meaning |
| --- | --- | --- |
| `[send-message] Sending message with sdk run config` | 710 | a turn started (`data.runConfig.agent`, `promptLength`, …) |
| `Main prompt finished` | 703 | a turn ended (`data.outputType`, `data.messageCount`) |
| `[chat-runtime] Freebuff session over; holding queued messages until rejoin` | 211 | the session ended |
| `Agent run cancelled by user (abort error)` | 96 | the turn was interrupted |

`data.outputType` is `lastMessage` (583) or `error` (120) — so the turn end
carries an outcome. A real pair from
`projects/projects/chats/2026-11-25T10-32-52/`:

```
10:32:52.318Z [send-message] Sending message with sdk run config  {"runConfig":{...,"maxAgentSteps":600}}
10:39:33.576Z Main prompt finished  {"outputType":"lastMessage","messageCount":4}
```

**`<config>/projects/<project>/chats/<id>/run-state.json`** — the resume
snapshot, `{sessionState, traceSessionId, output, inference}`, with
`output.type` `lastMessage` or `error`. Rewritten at message boundaries, so it
is a state record rather than an event stream. It is what `--continue` reads.

**`<config>/freebuff-live-<sha256(tokenKey)>.json`** — one lease per live
session: `{instanceId: "cli:<uuid>", model, tokenKey, ownerPid, expiresAt}`.
Removed on a clean exit and unlinked when expired. On this machine five exist
and four belong to live PIDs, so it does track liveness — but one file belongs
to a PID that is gone and still carries a future `expiresAt`, so the file alone
is not proof and must be paired with a `kill -0`.

The directory name is `basename(cwd)`, not the full path, so two checkouts with
the same directory name share a `projects/<name>/` tree. Worktrees created by
this tool are named uniquely, which avoids it in practice, but it is a
collision waiting for `--name` reuse.

### Events available, ranked by how much they can be trusted

| Event | Source | Contract |
| --- | --- | --- |
| turn ended | `Main prompt finished` in `log.jsonl` | internal debug log; shape may change |
| session ended | `[chat-runtime] Freebuff session over` | internal debug log |
| session exited | lease file removed | internal; lease also expires |
| result written | `.agent-result` | **ours**, stable |
| pane looks idle | tmux capture | TUI chrome, already fragile |

The first two are far better than pixels and still not a contract. The result
file stays the primary signal; a log tail is an *earlier* signal for the same
turn, not a replacement.

## 6. Completion notifications: nothing is emitted today

The question was whether Freebuff already emits OSC 9, OSC 777 or a bell, or
accepts a command to run on completion. It does none of these.

- The CLI layer never calls the renderer's notification API. The renderer
  wrapper exposes `triggerNotification(rendererPtr, text)` and the native
  library implements it (`writeNotification`, `writeOsc99Payload`,
  `writeSanitizedNotificationText`, and an `osc9`/`osc99`/`osc777` capability
  probe for `opentui-notifications`). `triggerNotification` has **no call site**
  in the CLI: the only occurrences are the FFI binding, its type declaration and
  its symbol-table entry.
- `setTerminalTitle` is in the same position — a renderer primitive with no
  caller. So `#{pane_title}` is not a usable busy/idle signal either, even
  though `src/utils/terminal-title.ts` exists.
- No BEL is written on turn completion. The escape sequences that do get
  written are OSC 52 (clipboard) and OSC 8 (hyperlinks).
- tmux does not forward an OSC notification to the outer terminal on its own,
  so even a build that emitted one would need an explicit arrangement (a
  `monitor-bell` setting or a hook). That is untested here — tmux is not on
  `PATH` in this environment — and it is why §8 ranks an OSC notification last.

What exists instead is `set-hook … pane-died` in tmux: the pane dying is a real
event, and `remain-on-exit` keeps the corpse around long enough to notice. That
covers "the process exited", not "the turn finished" — Freebuff stays at its
prompt after a turn, by design.

## 7. What works in a tmux pane, headless of the desktop app

| Capability | In a tmux pane | Evidence |
| --- | --- | --- |
| MCP client (stdio) | yes | client modules; spawns the server from `mcp.json` |
| MCP client (HTTP/SSE) | yes, per vendor docs | docs; no code path read |
| MCP host | no | no server transport in the bundle |
| `/mcp` inspection | no | not in the command registry |
| configurable hooks | no | no key, no file, no flag |
| completion notification | no | no call site (§6) |
| turn/session events on disk | yes | `log.jsonl`, `run-state.json` (§5) |
| trust prompt | yes, and it blocks | plain-terminal readline before the TUI mounts |
| ACP (`--acp`) | no | not in the flag set |
| initial prompt argument | no | `[prompt...]` is Codebuff-only |

The desktop app is a different surface: it reads a shared `~/.agents/mcp.json`
plus its own `~/.freebuff/mcp.json` for approvals, and has a Settings → MCP
screen. None of that is reachable from the CLI, and nothing here should be
planned as if it were.

## 8. Notify on exit, ranked by effort

"Notify" here means: `watch`/`--auto-stop` learns that the agent finished
without polling pane text. Effort is sized for one agent session each.

### 1. Free: tail the client's own turn log — **small**

Watch `<config>/projects/<worktree-name>/chats/<newest>/log.jsonl` for
`Main prompt finished`, and use `data.outputType` for the outcome. Pair it with
`[send-message] Sending message with sdk run config` so a re-read cannot fire
twice, and keep the pane poll as fallback.

- Cost: one resolver (project dir → newest chat dir) plus a JSONL tail. No new
  dependency, no vendor change, no new file format.
- Risk: it is a debug log, not a contract. Mitigation is already the design
  here: fall back to the pane and to `.agent-result` when the line never
  appears.
- Bonus: it lands within the same second the turn ends, where the idle window
  needs `--idle-seconds` of stillness before it will say the same thing.
- Limitation: per-turn, not per-session. A brief that produces a second turn
  fires twice; that is correct for "the agent finished", wrong for "the run is
  over". The result file stays the authority for the latter.

### 2. Free: `pane-died` as the session-exit event — **small**

`tmux set-hook -t fb-<name> pane-died` (plus `remain-on-exit on`) turns process
exit into a callback instead of a poll. Complements 1: 1 says "the turn ended",
2 says "the client is gone", and today the difference is invisible.

- Risk: a crash and a clean exit look the same; that is still better than the
  idle timer, which cannot tell either from a slow tool call.

### 3. Low: an MCP tool the brief calls when it is done — **medium**

Because Freebuff *is* an MCP client (§4), the tool can ship a tiny stdio MCP
server that exposes `supervisor_report` and have the brief call it. This is the
only in-band channel that exists, and it is vendor-sanctioned: MCP is a
documented feature, not a workaround.

- Cost: a JSON-RPC stdio server (bash can do it, badly; node is cleaner), a
  `.agents/mcp.json` per worktree, the trust prompt (§4), and a brief change.
- Value: the agent can report *during* a turn (blocked, needs input, refused),
  not only at the end. That is the part `log.jsonl` cannot give.
- Risk: a new moving part in the launch path, and a `mcp.json` in a worktree is
  repository-supplied code that has to be trusted — a security decision, not a
  default.

### 4. Not available: user hooks — **upstream**

No hook surface exists (§5). This needs a vendor change: a documented
`onTurnEnd`/`onSessionEnd` command in `settings.json`. The ask is small for
them and worth one issue, but nothing here can be built on it now.

### 5. Not available: an OSC notification — **upstream**

The renderer already implements `triggerNotification` and the OSC 9/99/777
writers (§6). The gap is one call site. Asking for "emit a notification on turn
end, gated by a setting" is a much smaller request than headless mode, and it
is not the duplicate the README warns about. It still does not help inside tmux
without passthrough, so it is a convenience for a desktop terminal, not the
foundation for this tool.

### 6. Not available: ACP — **upstream, unmerged**

`--acp` is not in 0.2.38. The README already tracks it; nothing changes here.

### Summary

| Option | Effort | Works today | Trust |
| --- | --- | --- | --- |
| turn log tail | S | yes | internal format |
| `pane-died` hook | S | yes | tmux contract |
| MCP `report` tool | M | yes | documented feature |
| user hooks | — | no | needs vendor |
| OSC notification | — | no | needs vendor |
| ACP | — | no | unmerged upstream |

Do 1 and 2 first: together they replace most of the pane guessing for a day of
work each. 3 is the one that adds a capability (in-turn reporting) rather than
replacing a heuristic.

## 9. Two corrections to the existing roadmap

**#66 says "Freebuff must host an MCP server" and lists that as what blocks
Concord.** It is backwards. Freebuff is an MCP *client*; it consumes servers.
Concord is an MCP server. So the integration #66 wants — an agent calling
`start_work` / `finish_work` — is available today through `.agents/mcp.json`,
with no vendor change and no hosting. What #66 actually needs is the trust gate
solved (§4) and a decision about a second source of truth. That is a cheaper
roadmap than the one written down.

**The worktree does not inherit the repository's `.agents/`.** The parent
lookup is `cwd/../.agents`, which from `.worktrees/<name>` is
`.worktrees/.agents`. Any plan that assumes "commit it at the root and every
session sees it" is wrong for this tool's layout.

## 10. Child issues

Filed from this document, each sized for one agent session:

| Issue | Title | Priority | Effort |
| --- | --- | --- | --- |
| [#74](https://github.com/MBanucu/freebuff-agent-supervisor/issues/74) | notify: read turn completion from the client's per-chat log.jsonl | p2 | S |
| [#75](https://github.com/MBanucu/freebuff-agent-supervisor/issues/75) | state: `--source log` for status, with the pane as fallback | p2 | S |
| [#76](https://github.com/MBanucu/freebuff-agent-supervisor/issues/76) | start: a worktree with `.agents/` hangs at the trust prompt | p2 | S |
| [#77](https://github.com/MBanucu/freebuff-agent-supervisor/issues/77) | docs: how a worktree gets MCP tools, and the trust gate | p3 | S |
| [#78](https://github.com/MBanucu/freebuff-agent-supervisor/issues/78) | upstream: emit a completion notification | p3 | S |
| [#79](https://github.com/MBanucu/freebuff-agent-supervisor/issues/79) | spike: an MCP report tool the brief calls in-turn | p3 | S |

Order: #75 needs #74's parser. #77 documents a path that #76 makes safe, so it
follows it. #74 and #76 are independent of everything else and can go in
parallel. #78 and #79 are independent of the rest and of each other.

Nothing here adds a dependency. The two that touch the launch path (#76, #79)
are the ones to be careful with: both involve trusting repository-supplied code.

## Appendix: reproducing this

```bash
freebuff --version                       # 0.2.38
freebuff --help                          # the five options in §2
ls ~/.config/manicode                    # settings, credentials, leases, projects
cat ~/.config/manicode/settings.json     # the 15 keys in §3
cat ~/.config/manicode/freebuff-metadata.json
cat ~/.config/manicode/trusted-agent-dirs.json

# The bundle is a Bun single-file binary; no `strings` needed:
python3 - <<'PY'
import os
config = os.environ.get('FREEBUFF_CONFIG_DIR') or os.path.expanduser('~/.config/manicode')
d = open(os.path.join(config, 'freebuff'), 'rb').read()
for needle in [b'MCPConfig', b'mcp.json', b'triggerNotification',
               b'setTerminalTitle', b'run_file_change_hooks', b'--trust-agents']:
    print(needle.decode(), d.count(needle))
PY

# Turn events, from a chat this machine already ran:
python3 - <<'PY'
import json, glob, collections, os
config = os.environ.get('FREEBUFF_CONFIG_DIR') or os.path.expanduser('~/.config/manicode')
c = collections.Counter()
for p in glob.glob(os.path.join(config, 'projects/*/chats/*/log.jsonl')):
    for line in open(p, errors='replace'):
        try: c[json.loads(line).get('msg','')] += 1
        except Exception: pass
for m in ('Main prompt finished',
          '[send-message] Sending message with sdk run config',
          '[chat-runtime] Freebuff session over; holding queued messages until rejoin'):
    print(c[m], m)
PY
```

Counts in §5 come from the 107 chat directories present on this machine on
2026-11-26 and will drift as more runs happen — the numbers were already
moving between two reads during this exploration.
