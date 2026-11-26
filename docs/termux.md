# Subagent mode on Termux/Android

What blocks running `spawn-freebuff-agent` with real agents from a phone
checkout, established from the repository and one read-only pass over an
attached Android device.

Roadmap only: nothing in this document changes the tool. The children are at the
end and in [#97](https://github.com/MBanucu/freebuff-agent-supervisor/issues/97).

- **Issue:** [#89](https://github.com/MBanucu/freebuff-agent-supervisor/issues/89)
- **Explored:** 2026-11-26
- **Device:** XPLORE 2, Android 15 (SDK 35), Termux 0.118.3, aarch64
- **Method:** read-only. The repository (the tool, both suite headers, both CI
  workflows, `docs/`), plus read-only `adb` queries against the phone:
  `getprop`, `pm list packages`, `dumpsys deviceidle`, `dumpsys power`,
  `settings get`, `ls`. No reboot, no screen lock/unlock, no write to the
  device, no Termux shell, no Freebuff session. The Termux prefix
  (`/data/data/com.termux/files/usr/bin`) is unreadable to the `adb` shell user
  and there is no root, so installed package presence was **not** checked on
  this device; it is read from the Termux package index instead.

Every claim is marked with its evidence:

| Mark | Meaning |
| --- | --- |
| **[repo]** | visible in this repository: a line, a grep or a document |
| **[package]** | Termux bootstrap or package index, cited in the appendix |
| **[device]** | read from the attached phone on 2026-11-26 |
| **[unverified]** | needs a Termux shell or a screen-lock run; the exact command is given |

## 1. The command surface

"Subagent mode" here is the full path: `start` (worktree, brief, detached tmux,
`wait_ready`, send proof), `status`/`sessions`, `watch`/`autostop`, `gui --serve`
and the agent's own `git`/`gh` finish. Bash builtins (`printf`, `read`, `local`,
`mapfile`, `kill -0`) are not listed; these are the external commands the tool
executes. **[repo]**

| Command | Used for | Termux origin | Verdict |
| --- | --- | --- | --- |
| `bash` 4+ | the tool itself (`mapfile`, arrays, `printf -v`) | bootstrap | present |
| `git` | worktree add/list, status, log, remote | `pkg install git` | one package |
| `tmux` | every session command, `#{pane_tty}`, `#{session_activity}` | `pkg install tmux` | one package |
| `stty -a -F` | raw-mode check in `wait_ready` and `status` | `coreutils`, bootstrap (GNU) | present |
| `date` | `+%s`, `-u +FORMAT` only | `coreutils`, bootstrap | present |
| `awk` | poll counts, elapsed seconds, ledger | `gawk`, bootstrap | present |
| `sed`, `grep`, `head`, `tail`, `sort` | pane parsing, JSON, inventory | bootstrap (`sed`, `grep`, `findutils`, `coreutils`) | present |
| `mkdir`, `cp`, `cat`, `basename`, `dirname`, `sleep`, `nohup`, `cksum` | worktree setup, logs, hashing fallback | `coreutils`, bootstrap | present |
| `sha256sum` (or `shasum`, `openssl`) | brief hash, window hash | `coreutils`, bootstrap | present |
| `setsid` | detach the autostop watcher; `nohup` is the fallback | `util-linux`, bootstrap | present, optional |
| `python3` | `gui --serve` only | `pkg install python` | optional |
| `ttyd` | `gui --serve --ttyd` only | `pkg install ttyd` (1.7.7-5) | optional |
| `gh` | issue title/url, PR column, and the brief's own PR step | `pkg install gh` (2.98.0) | optional for `start`, needed to finish |
| `freebuff` | the agent itself | not a Termux package; glibc binary | **the blocker** |
| `nix-shell` | last-resort tmux lookup | not in stock Termux | dead branch here |
| `flock` | — | — | **not called** |
| `ps` | — | — | **not called** (`ps` is an alias for `sessions`) |
| `mktemp -d` | — | — | **not called by the tool**; the test harness uses it |

The four commands #89 asks about that the tool never calls are not a problem
at all:

- **`flock`** — zero occurrences in `spawn-freebuff-agent`. The tool has no
  lock file; the brief ledger is append-and-read, not locked. **[repo]**
- **`date -d`** — zero occurrences. Deadlines are `date +%s` arithmetic and log
  stamps are `date -u '+%Y-%m-%dT%H:%M:%SZ'`; both are POSIX/GNU forms that
  Termux's coreutils `date` supports. **[repo]**
- **`ps`** — zero occurrences. Session liveness is `tmux has-session`; watcher
  liveness is the shell builtin `kill -0` on the pid `start` recorded. The word
  `ps` in the dispatch is `sessions|ps)`, a convenience alias. **[repo]**
- **`mktemp -d`** — zero occurrences in the tool. Worktrees live at
  `$ROOT/.worktrees/<name>`, not in a temp dir. `test/lib.sh` uses
  `mktemp -d`, which honours `TMPDIR` (Termux sets it to `$PREFIX/tmp`).
  **[repo]**

So the install line for a fresh Termux is:

```bash
pkg install tmux git gh python ttyd
```

`coreutils`, `gawk`, `grep`, `sed`, `findutils`, `procps`, `util-linux` and
`termux-tools` are in the bootstrap. `pkg install coreutils` is harmless but
redundant; it is named in the README child only to make the dependency explicit.

## 2. Discovery: `tmux_bin` and `FREEBUFF_TMUX`

`tmux_bin` tries, in order: **[repo]**

1. `FREEBUFF_TMUX` — returned unconditionally, even if the path is wrong;
2. `command -v tmux`;
3. `"${XDG_CACHE_HOME:-$HOME/.cache}/wireless-adb-keeper/tmux.path"`, if
   executable;
4. `nix-shell -p tmux --run 'command -v tmux'`.

On Termux this is not desktop-only:

- Termux puts `$PREFIX/bin` on `PATH`, so `command -v tmux` resolves
  `$PREFIX/bin/tmux`. **This is the normal case.**
- `FREEBUFF_TMUX=$PREFIX/bin/tmux` is the explicit escape hatch, and it works
  because it is consulted first.
- The cache path is under `$HOME/.cache`, which is writable in Termux's private
  home. The directory name still says `wireless-adb-keeper` (the project this
  was extracted from), which is cosmetic only.
- `nix-shell` is not part of stock Termux. This phone has `com.termux.nix`
  installed **[device]**, but the branch is only reached when tmux is absent, so
  it does not matter for the normal path. If it *is* reached, it is a slow
  interactive Nix build, not a fast fallback.

`gui/server.py` repeats the lookup without the cache: `FREEBUFF_TMUX` or
`shutil.which("tmux")`. Same answer. **[repo]**

Verdict: **no change needed for tmux discovery.** The only possible improvement
is renaming the cache directory, which nothing in #89 asks for.

## 3. The ready gate: `pane_tty` and `stty -F`

`wait_ready` needs two facts on every poll: **[repo]**

```bash
tty=$("$tmux" display-message -p -t "$session" '#{pane_tty}')
stty -a -F "$tty" | grep -q -- '-icanon' &&
    printf '%s' "$pane" | grep -q 'Enter a coding task'
```

`#{pane_tty}` is the path of the pty tmux allocated for the pane, not a Linux
path the tool constructs. tmux uses `openpty()`/`posix_openpt()` on every Unix
it supports, so the path is `/dev/pts/N` on Android exactly as on Linux (macOS
uses `/dev/ttysN`). The format is therefore not Android-specific; **access to
it** is the question.

Three things could break the check on Termux:

1. **`stty` not being GNU.** `-F FILE` is a GNU extension; toybox's `stty` does
   not have it. Termux's `stty` comes from `coreutils`, and `$PREFIX/bin`
   precedes `/system/bin` on `PATH`, so the GNU one wins. A user who reorders
   `PATH` to prefer `/system/bin` gets toybox and a check that always fails.
   **[package]**
2. **The pty not being openable.** Termux runs as the app uid and owns the ptys
   its own tmux created, so `stty -F` can open them. The `adb` shell user is a
   different uid and domain and gets `EACCES` on `/dev/pts` **[device]** — that
   is evidence the directory is protected, not that Termux cannot read its own
   pane.
3. **`stty` missing entirely.** It is in the bootstrap, so this needs a broken
   install. **[package]**

The failure mode is the real defect: if `stty` exits non-zero on every poll,
`wait_ready` treats it as "not raw yet" and burns the whole `--ready-timeout`
(120s by default), then kills the pane and reports only "never ready". A hard
error is indistinguishable from a cold start. `status` has the same conflation:
a tty it cannot read is reported `input=canonical` rather than `unknown`.
**[repo]**

**[unverified]** No Termux shell was opened, so this exact command was not run:

```bash
tmux new -d -s probe -x 180 -y 55 'freebuff --cwd ~/probe --trust-agents'
tty=$(tmux display-message -p -t probe '#{pane_tty}')
printf 'tty=%s\n' "$tty"
command -v stty
stty -a -F "$tty" | grep -o -- '-\?icanon'
```

Expected on a healthy Termux: `tty=/dev/pts/N`, `stty` is
`$PREFIX/bin/stty`, and the flag is `-icanon` once the TUI is up. The readiness
child (#100) is what should turn a failure of this command into a named error
instead of a 120-second wait.

## 4. Paths and state

The tool writes only inside the target repository and its git dir: **[repo]**

| Path | What |
| --- | --- |
| `$ROOT/.worktrees/<name>/` | the worktree |
| `$ROOT/.worktrees/<name>/.task.md` | the brief |
| `$ROOT/.worktrees/<name>/.agent-result` | the agent's result |
| `$ROOT/.worktrees/<name>/.supervisor.log` | transitions, readiness, autostop, wake-lock evidence |
| `$ROOT/.worktrees/<name>/.refusal` | a recorded vendor refusal |
| `$ROOT/.supervisor-briefs.jsonl` | the last 20 sent-brief hashes |
| `$ROOT/.git/info/exclude` | ignore entries for the above |
| `local.properties` | optional `sdk.dir` |

No path in the tool hardcodes `/home`, `/tmp` or `/data/data`. `$ROOT` defaults
to the git top level, so a checkout under Termux's home
(`/data/data/com.termux/files/home/...`) works, and `HOME` only appears in the
tmux cache and `freebuff_bin`'s `$HOME/.local/bin/freebuff` fallback. **[repo]**

Two Termux-specific path facts:

- **`/tmp` is not writable by the Termux uid.** On this phone `/tmp` is
  `drwxrwx--x shell shell` **[device]**: the Termux app can traverse it but not
  create files. The tool never writes there, but the README's examples use
  `gui --snapshot /tmp/agents.html` **[repo]**, so that exact command fails with
  `Permission denied`. Use `${TMPDIR:-/tmp}/agents.html`: Termux sets `TMPDIR`
  to `$PREFIX/tmp`. `gui --serve` is unaffected — its rendered page goes through
  Python's `tempfile.TemporaryDirectory`, which honours `TMPDIR`. **[repo]**
- **The checkout must be on a POSIX filesystem.** Termux's shared storage
  (`~/storage/shared`, `/sdcard`) is FUSE: no Unix permissions, no symlinks, no
  exec bit. `git worktree add` and `chmod +x` fail there. Keep the repository
  under `$HOME` (the private ext4 data directory), not under shared storage.
  **[unverified]** in the sense that this document did not attempt it; it is a
  documented Termux property.

The Freebuff client's config (`~/.config/manicode`) is also under `$HOME`, so
the per-chat `log.jsonl` that future #74/#75 want to read is available at a
writable path. **[repo]** (path from `docs/freebuff-integration.md`).

## 5. Screen lock, Doze and the phantom process killer

Three Android layers can end a run that a desktop would keep: Doze/app standby
suspends CPU and network, the phantom-process killer (Android 12+) reaps excess
child processes, and vendor battery managers kill background apps. Termux's
documented mitigations are a partial wake lock (`termux-wake-lock`), battery
optimisation exemption, and disabling the phantom-process monitor. **[package]**

This phone is already prepared: **[device]**

| Check | Observed |
| --- | --- |
| `dumpsys deviceidle whitelist \| grep termux` | `user,com.termux,10514` — battery-optimisation exempt |
| `dumpsys power \| grep -i termux` | `PARTIAL_WAKE_LOCK 'termux:service-wakelock' ACQ=-1d0h27m...` held by `com.termux` (uid 10514, pid 7192) |
| `settings get global settings_enable_monitor_phantom_procs` | `false` |
| `device_config get activity_manager max_phantom_processes` | `null` |
| `pm list packages \| grep termux` | `com.termux`, `.boot`, `.gui`, `.nix`, `.adbbridge`, `.styling` |
| `dumpsys package com.termux` | version 0.118.3, installed 2026-11-17 |

So on **this** phone all three mitigations are in place, and a wake lock has
been held for more than a day. That is operator setup, not something the tool
does or checks. A fresh Termux is not in this state.

What that means for each process, all of which are children of the Termux app:

- **the detached tmux server** — survives a screen lock only while the app's
  process survives. With the wake lock and the whitelist it should; on a stock
  install Doze or an OEM manager can freeze or kill it, and a detached tmux
  server has no foreground notification of its own. **[unverified]**
- **the autostop watcher** — `start` uses `setsid` when available, `nohup`
  otherwise, so it survives the launching shell but not the app. If it is
  reaped, `sessions` reports `WATCHER dead` while the session stays live: a
  silent degradation visible only in that column. **[repo]**
- **`gui --serve`** — a foreground Python process. Started in a Termux terminal
  it dies with the app; started inside a tmux session it shares the tmux
  server's fate. It binds `127.0.0.1`, so the phone's own browser is the client
  and no other device can reach it. **[repo]**

**[unverified]** The screen was not locked (the task forbids it), so none of
this is a lock test. It is configuration evidence plus source reading. The
wake-lock child (#99) is where a real lock/unlock run belongs, and it should
record what happened rather than assume.

`adb shell ps -A` shows only `com.termux` and `com.termux.adbbridge` as Termux
processes; tmux and the agent run under the app uid and are not visible to the
`shell` user, so this check cannot confirm a live server either way. **[device]**

## 6. What fails today, as a command

Run inside Termux, in a checkout under `$HOME`.

1. **`command -v freebuff` → nothing, and `start` dies with
   `freebuff not found; set FREEBUFF_BIN`.** Freebuff is not a Termux package.
   The npm package downloads a Bun-compiled, glibc-linked binary (its loader is
   `/lib/ld-linux-aarch64.so.1` on an arm64 phone); Termux is bionic, so the
   binary cannot exec even when it is present. If `~/.local/bin/freebuff`
   exists, running it prints `No such file or directory` for the missing
   loader. **This is the only hard blocker.** It is solved outside this repo —
   a glibc layer such as the maintainer's `freebuff-native-termux`,
   `proot-distro`, or a remote host — and the tool cannot paper over it.
   **[repo]** (the repo records the same client as a 138 MB ELF in
   `docs/freebuff-integration.md`) + **[package]** (the npm build is glibc;
   Termux is bionic).
2. **`spawn-freebuff-agent gui --snapshot /tmp/agents.html` →
   `Permission denied`.** `/tmp` is shell-owned and not writable by the Termux
   uid. Use `$TMPDIR/agents.html`. **[device]**
3. **`spawn-freebuff-agent start --issue 89` on a fresh install →
   `start: tmux not found; install tmux or set FREEBUFF_TMUX`.** Fix:
   `pkg install tmux`. **[repo]**
4. **`spawn-freebuff-agent gui --serve` without Python.** The tool already says
   `gui: --serve needs python3 (pkg install python on Termux); the rest of the
   CLI works without it`. Fix: `pkg install python`. **[repo]**
5. **`gui --serve --ttyd` without ttyd.** The dashboard still renders, with no
   terminal links, and `/tty/<name>` answers 503. Fix: `pkg install ttyd`.
   **[repo]**
6. **`gh pr list` / the agent's `gh pr create` without gh.** The PR column is
   `null` and the brief's finish step cannot run. `start` still works (it falls
   back to `issue #N` and a GitHub URL), so this fails late, in the agent's
   turn. Fix: `pkg install gh && gh auth login`. A wrapper script is fine: the
   tool uses `command -v` and passes argv, never a shell string. **[repo]**
7. **`git worktree add` under `/sdcard`.** Shared storage has no permissions or
   symlinks; the worktree creation fails. Fix: keep the checkout under `$HOME`.
   **[unverified]** here, documented Termux behaviour.
8. **`stty -a -F "$(tmux display-message -p '#{pane_tty}')"`** — see §3. It
   should work with GNU stty; if it does not, the current failure is a 120s
   timeout, not this command's error. Fix: #100. **[unverified]**
9. **`flock`, `date -d`, `ps`, `mktemp -d`** — not run by the tool, so there is
   no failing command to report. **[repo]**

## 7. Verdict

Ranked by what actually blocks a phone run:

1. **Freebuff itself.** No Android/bionic build; the client is a glibc binary.
   Everything else is downstream of solving this, and it is outside this
   repository. Until it is solved, `start` cannot launch, no matter how
   Termux-clean the supervisor is.
2. **Background survival.** Not a code bug: the app must hold a wake lock, be
   exempt from battery optimisation and, on Android 12+, have the phantom
   process monitor off. This phone has all three; a fresh install does not. The
   tool does not check or request any of them (#99).
3. **Readiness error reporting.** `pane_tty` is portable and GNU `stty` is
   present, but a failing `stty -F` is reported as a timeout and `status` calls
   it `canonical`. Small, invisible until it happens (#100).
4. **Path and example nits.** `/tmp` is not writable; the README `--snapshot`
   examples need `TMPDIR`. Shared storage cannot hold a worktree. Docs-sized
   (#101).
5. **Everything else works.** tmux discovery, `FREEBUFF_TMUX`, `setsid`/`nohup`,
   `gh`/`python3`/`ttyd` as optional packages, hashing, date arithmetic, and
   the state files are all Termux-compatible as written. `flock`, `date -d`,
   `ps` and `mktemp -d` are not used.

One prerequisite makes the rest of this list reachable: install a Freebuff
client that can execute on the phone. The findings doc stops there because the
fix is a packaging problem in another project, not a change to this one.

## 8. Children

Filed from this document; the umbrella is [#97](https://github.com/MBanucu/freebuff-agent-supervisor/issues/97).

| Issue | Title | Priority | Effort |
| --- | --- | --- | --- |
| [#98](https://github.com/MBanucu/freebuff-agent-supervisor/issues/98) | start: a Termux preflight that names the missing command | p2 | S |
| [#99](https://github.com/MBanucu/freebuff-agent-supervisor/issues/99) | lifecycle: an opt-in Termux wake lock for runs that outlive the screen | p2 | S |
| [#100](https://github.com/MBanucu/freebuff-agent-supervisor/issues/100) | readiness: report a failing raw-mode check instead of a 120s timeout | p2 | S |
| [#101](https://github.com/MBanucu/freebuff-agent-supervisor/issues/101) | docs: Termux requirements and TMPDIR-safe examples | p3 | S |

Order: #98 first, because it turns every other failure into a named command.
#99 and #100 are independent of each other and of #98. #101 follows #88 if that
move lands first, and only edits the Requirements section and the examples.

None of them adds a runtime dependency. The wake lock is the only one that calls
a new binary, and it is optional and never fatal.

## Appendix: reproducing this

On the attached device, read-only:

```bash
adb shell 'getprop ro.product.model; getprop ro.build.version.release; getprop ro.build.version.sdk'
adb shell 'pm list packages | grep -i termux'
adb shell 'dumpsys package com.termux | grep -E "versionName|firstInstallTime"'
adb shell 'dumpsys deviceidle whitelist | grep -i termux'
adb shell 'dumpsys power | grep -i termux'
adb shell 'settings get global settings_enable_monitor_phantom_procs'
adb shell 'device_config get activity_manager max_phantom_processes'
adb shell 'ls -ld /tmp /dev/pts; ls /dev/pts'
```

Inside Termux, the command inventory this document was derived from:

```bash
for c in bash git tmux stty setsid flock date ps mktemp python3 ttyd gh freebuff nix-shell; do
    printf '%-8s %s\n' "$c" "$(command -v "$c" || printf missing)"
done
pkg show tmux git gh python ttyd 2>/dev/null | grep -E '^(Package|Version):'
```

The repository side:

```bash
grep -nE 'flock|mktemp|date -d|(^|[^[:alnum:]_])ps([^[:alnum:]_]|$)' spawn-freebuff-agent
grep -n 'pane_tty\|stty -a -F' spawn-freebuff-agent
grep -n 'tmux_bin()\|freebuff_bin()' -A 20 spawn-freebuff-agent
```

Termux package facts: the bootstrap list in `termux-packages`
`scripts/build-bootstraps.sh` (bash, coreutils, gawk, grep, procps, sed,
findutils, util-linux), and the package index entries for `gh` (2.98.0) and
`ttyd` (1.7.7-5), read on 2026-11-26. The wake-lock and phantom-process
guidance is from `termux-tools` (`termux-wake-lock`) and the Termux wiki.
