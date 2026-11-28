# Static snapshot and the browser GUI

## Static snapshot

`gui --snapshot FILE [--watch N]` writes one self-contained HTML page from
`sessions --json`: one card per session with name, state, idle time (only while
the session can still take a turn), watcher, worktree, result, branch, the
model it was launched with and its cost class (`free`, `2x`, ...), PR, and
— for a session with a worktree — the
commit and the result file's `tests` line. A done session is green, a working
one amber, a failed or refused one red, and a session with no worktree carries
a `no worktree` tag. A run that chose no model has no model row, so `free` and
`2x` sessions are told apart at a glance without grepping a log.

```bash
spawn-freebuff-agent gui --snapshot ${TMPDIR:-/tmp}/agents.html
spawn-freebuff-agent gui --snapshot ${TMPDIR:-/tmp}/agents.html --watch 5
```

There is no server, no network and no auth: the file is opened directly or
served by any static host, so it works on a phone and nothing listens to be
attacked. There are no external assets — CSS is inline and there is no
script — so `file://` works offline and a strict CSP cannot break the view
(the page declares `default-src 'none'; style-src 'unsafe-inline'; img-src
data:; connect-src 'self'` — the last one only so Chrome DevTools' own
`/.well-known` probe is not blocked and does not fill the console). That
`<meta>` is all a static file can carry: a `file://` page has no headers.
`gui --serve` keeps it for the same markup and adds the framing, `nosniff` and
referrer headers a meta tag cannot express (see the threat model). `--watch N` rewrites the file every N seconds and adds
`<meta http-equiv="refresh" content="N">`, so an open browser follows along
without JavaScript. Without it, a single snapshot is written and the command
exits.

An empty repository renders `no sessions` instead of an empty table. Every
rendered value is HTML-escaped, because branch names, PR URLs, commit subjects
and the `tests` line are arbitrary text. The page is read-only: it offers no
buttons that only pretend to act. `gui --snapshot` never receives a form
nonce, so a static file has no forms at all; only `gui --serve` adds them (see
below), because only a server can check the nonce back.

## Browser GUI

`gui --serve` serves that page over HTTP from python3's standard library, with
no third-party packages. `GET /` runs the same `gui --snapshot` renderer into a
temporary file, so the server owns no second markup, and `/api/sessions` is
`sessions --json` verbatim — the CLI stays the only source of state.

```bash
spawn-freebuff-agent gui --serve                    # http://127.0.0.1:7788
spawn-freebuff-agent gui --serve --port 8080 --token "$TOKEN"
spawn-freebuff-agent gui --serve --read-only
spawn-freebuff-agent gui --serve --ttyd             # terminal link per card
```

- `GET /` renders one card per session, including `worktree=missing` orphans.
- `GET /tty/<name>` redirects to a ttyd viewer for that session, with `--ttyd`.
- `GET /api/sessions` returns `sessions --json` verbatim.
- `GET /api/session/<name>/pane` returns `status NAME --json`, or 404 when the
  name has no worktree.
- `POST /api/session/<name>/stop[?graceful=1]` runs `stop NAME`, or
  `stop NAME --graceful`. A **cookie-authenticated form POST** is answered
  with a confirmation page and changes nothing; the page's confirm form posts
  `?confirm=1` and runs the stop, then `303` to `/`. The first POST is the
  stray-click guard: clicking a card's Stop cannot end a live session.
- `POST /api/session/<name>/send` runs `send NAME TEXT`, with the text taken
  from a JSON body `{"text": "..."}` and never from the URL.
- `POST /api/gc[?dry=1]` runs `gc`, or `gc --dry-run`.
- Codes: 401 for a missing or wrong token, 421 for a `Host` this server does
  not answer for (checked before auth), 400 for a name that fails
  `^[A-Za-z0-9_-]+$` or a body that is not JSON, 404 for an unknown session
  (no worktree, the pane route's rule), 403 in read-only mode, for a missing or
  wrong form nonce, or for a foreign `Origin`; 409 when the CLI refuses; 413
  for a body over 64 KiB; 303 after a successful form action.

### Forms, the nonce and Origin

`GET /` renders the actions as plain `<form method="post">` elements, so the
page works with JavaScript disabled and is testable with curl:

- a `gc --dry-run` form above the cards, only when something is live;
- `Stop` and `Stop (graceful)` on a running session's card, but not on one
  whose state is already terminal (`done`, `stopped`, `failed`, `blocked`).

Every form carries a hidden `nonce` field holding a per-server random
`form_nonce` generated at startup. A POST that authenticated with the cookie
must present it, compared with `hmac.compare_digest`; a missing or wrong value
is `403`, not a silent no-op. A POST whose `Origin` header is present and does
not match the request's `Host` is also `403`, because two services on
`127.0.0.1` are same-site for a cookie (the port is not part of the site) and
`SameSite=Strict` therefore does not separate them.

A **bearer-token POST without a nonce still works**: a caller that already
read the secret keeps the `202` behavior from #22, which is what curl and the
CLI tests use. The nonce and Origin checks are for the cookie path only.

A successful form action **redirects, never re-renders**: `303 See Other` to
`/`, so a refresh is a GET and cannot replay the stop. The gc report cannot fit
in a redirect body, so `gc --dry-run` stashes its output under a one-shot key
and redirects to `/?gc=<key>`; that GET shows it once, and a refresh shows the
plain dashboard. `--read-only` renders a page with zero `<form>` elements and
still answers every POST `403`, so a reader is never offered a button whose
only outcome is a refusal.

### Live terminal through ttyd

`gui --serve --ttyd` adds a `terminal` link to every session card that has a
worktree. Following it is `GET /tty/<name>`, which starts one ttyd for that
session on demand and redirects the browser to it:

```
ttyd -p PORT -i 127.0.0.1 -c fb:TOKEN -o tmux attach -t fb-<name>
```

- **Read-only by default.** ttyd is read-only unless `-W` is passed, so a
  default viewer carries no write flag at all. ttyd 1.7.x has no `-R`: it was
  removed when read-only became the default, which is why the issue that asked
  for `-R` is implemented as "no `-W`". `--interactive` adds `-W` and is the
  only way to type into an agent from a browser.
- **Loopback and authenticated.** `-i 127.0.0.1` keeps the viewer on this host
  and `-c fb:<token>` derives basic auth from the server token, so the redirect
  never points at an unauthenticated port. The browser asks once for the
  credential: user `fb`, password the GUI token.
- **One viewer per session.** A second click reuses the running ttyd instead of
  starting another, `-o` makes ttyd exit when its tab disconnects, and the
  server terminates any viewer still running when it stops (including on
  `SIGTERM`).
- **`--read-only` refuses `--interactive`** at startup with exit 2 rather than
  silently downgrading it.
- **Codes:** `302` to the viewer, `409` when `fb-<name>` is not running, `404`
  for a name with no worktree, `400` for a name that fails the same validation
  as every other route, and `503` when ttyd is missing.
- **Without ttyd** the server still starts: the dashboard renders with no
  terminal links and one line saying why, instead of returning a 500.

`FREEBUFF_TTYD` names the binary. When it is set, PATH is not consulted, so
pointing it at a path that does not exist means "no ttyd" — useful on a
machine that has one installed but should not offer it.

Maintenance caveat: ttyd's last tag is 1.7.7 (March 2024). The repository still
receives commits, but distro packages lag, so check `ttyd --version` before
relying on a packaged build. The integration is optional for exactly that
reason: without ttyd everything else behaves as before.

An action is one CLI call and nothing else: a non-form caller gets `202` with
the CLI's own `key=value` lines, a form submission gets `303` to the dashboard
(on success; the gc report travels under the one-shot key above), so there is
no second result vocabulary to keep in step. On failure it returns the CLI's
exit status and message instead — `409` for exit 1, which is a session in the
wrong state, `500` otherwise — as a page for a form caller and as text for the
API. That is what lets a
browser tell "stopped" from "still busy" after a graceful stop, rather than
reading a refusal as success. The name is validated before it reaches a path or
a subprocess, the `send` text is passed as a single argv element and never
through a shell, and the token is still required on every POST even on loopback,
so a page in another tab cannot stop an agent. `--read-only` answers these
routes `403` rather than hiding them, so a caller learns why.

The token is compared in constant time and accepted as
`Authorization: Bearer T`, as an `fb_token` cookie, or as `?token=T` on a GET
that then sets the cookie. Without `--token`, one is generated and printed
once to stderr; it is never written to a log file. The server binds
`127.0.0.1` by default and refuses a non-loopback `--host` unless `--token`
was given explicitly. Binding to `0.0.0.0` exposes the pane of every agent to
the LAN, so use it only behind a reverse proxy (Caddy, Tailscale Serve) that
terminates TLS — this server does not.
