# Threat model and deployment

The server is one shared secret in front of an inventory and three actions on
agents that each have a shell. This section is what that protects, what it does
not, and how to expose it off this host without getting it wrong.

### Loopback is the default, and the only mode that is safe to leave on

`gui --serve` binds `127.0.0.1:7788` (`--port 0` picks a free port and prints
the URL). Nothing outside the machine can connect, so the network is not part
of the attack surface at all. A non-loopback `--host` exits 2 unless `--token`
was passed **explicitly**: a generated token does not count, so `--host 0.0.0.0`
typed by accident fails instead of quietly opening a dashboard to the LAN.

Loopback is still authenticated. The token is required on every route,
including `GET /`, because "local" is not the same as "yours".

### What the token protects

One secret per server, compared with `hmac.compare_digest`, accepted three
ways: `Authorization: Bearer T`, the `fb_token` cookie, or `?token=T` on a GET,
which sets the cookie. The cookie is `HttpOnly`, `SameSite=Strict` and
`Path=/`, with no `Secure` flag and no expiry, because there is no TLS and it
should die with the browser. Without `--token` the server makes 24 random bytes
(`secrets.token_urlsafe`, 32 URL-safe characters), prints it once to stderr,
and never writes it anywhere; a restart without `--token` therefore means a new
secret, and the old one is gone rather than rotatable.

Against anything that does not hold the secret, the token is the whole
difference between reading and doing nothing:

- **Read:** the session inventory, each session's pane tail, commit subject,
  dirty flag and PR — branch names, command output and whatever the agent has
  on screen.
- **Act:** `stop`, `stop --graceful`, `send TEXT` and `gc`. `send` types into
  the agent's TUI, and the agent has a shell in its worktree, so a token is
  effectively at least the agent's authority, not just a dashboard's.

There is no per-user identity, no per-session scope, no expiry and no record of
*who* acted: the log line is client address, method and path only. Every holder
has every route. `--read-only` is the only reduction and it is a flag on the
whole server (403 on POST), not a property of a token.

### What the token does not protect

- **It is not encryption.** The secret, the pane text and the `send` text are
  plain HTTP. On a LAN anyone on the path can read them and replay the token.
  There is no TLS, no HSTS and no certificate handling in this server.
- **It leaks through URLs.** The bootstrap `?token=T` is in the address bar and
  the browser history on purpose. The server logs only the path
  (`log_message` strips the query), but a reverse proxy or access log in front
  records the full request line. Treat that first URL as a secret and keep
  query strings out of proxy logs.
- **It is only as good as its storage.** `--token "$TOKEN"` puts it in shell
  history, `ps` and tmux scrollback. Prefer letting the server generate one and
  reading it from stderr.
- **It has no rate limit or lockout.** A wrong token is a 401 and nothing else,
  so guessing is bounded only by the 192-bit secret.
- **It does not make a browser page trustworthy on its own.** Cookies are
  scoped by host, not port, so another service on `127.0.0.1` is same-site for
  `fb_token` and can make the browser send an authenticated POST. The
  server-rendered forms reduce that: a cookie POST needs the page's per-server
  nonce and must not present a foreign `Origin`, so a page that never saw this
  dashboard cannot assemble a valid action. That is defence in depth, not a
  second identity: the nonce is visible to anything that can read the page
  (a token holder already reads every pane), and a caller that sends no
  `Origin` and holds a bearer token bypasses the nonce on purpose for curl
  compatibility. Treat anything else on the same host as able to read the
  dashboard if it has the token.
- **`--read-only` is not a second boundary.** It answers POST with 403 for
  everyone, which is the point, but a token holder still reads every pane.

### Response headers: framing, referrer and the CSP

The served page is interactive, so the server sends the headers a `<meta>` tag
cannot express. Every response carries them — the dashboard, `/api/*`, the
`303` after a form action, and the `401`, `403`, `404` and `421` refusals —
because a refusal is still a document a browser renders.

| Header | Value | What it stops, and what it does not |
| --- | --- | --- |
| `Content-Security-Policy` | `default-src 'none'; style-src 'unsafe-inline'; img-src data:; connect-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'` | Injected markup cannot load or run anything: no script, no object, no external style, no framing, and no injected `<base>` retargeting a form. `style-src 'unsafe-inline'` is required by the page's single inline `<style>`; there is no script, no `unsafe-inline` for script and no `unsafe-eval`. It does **not** stop a token holder — a holder can read every pane and POST every action without a browser — and it does not replace HTML-escaping: escaping is still what keeps pane text from being markup. |
| `X-Content-Type-Options` | `nosniff` | A browser may not re-interpret a JSON or text answer as HTML or script by sniffing; `Content-Type` is the only type. |
| `X-Frame-Options` | `DENY` | The older clickjacking control, for a browser that ignores `frame-ancestors`; both are sent. |
| `Referrer-Policy` | `no-referrer` | No `Referer` leaves the page. A card links to the PR on github.com, and the URL may still carry the bootstrap `?token=` when that link is clicked; without this header the full dashboard URL, secret included, would travel to a third party. |

`form-action 'self'` does not break the POST → `303` flow: the form targets
this server and the redirect is a navigation, not a second submission. The
suite asserts it on the wire. The static `--snapshot` page keeps its narrower
`<meta>` policy, because a file opened over `file://` has no headers; where
both apply the two policies agree, so the intersection changes nothing.

### Host validation and DNS rebinding

The server answers only the names it serves: `127.0.0.1`, `localhost` and
`[::1]`, each with or without a port, plus the configured `--host` and any
`--allow-host NAME` (repeatable). Anything else is `421 Misdirected Request`
and reaches no route — the check runs before the token check, so not even a
bearer caller gets an answer under a foreign name.

The reason is DNS rebinding. A page on `evil.example` can re-resolve that name
to `127.0.0.1`, and its own script then speaks to this server as a same-origin
peer; every loopback port is the same site for a cookie. The random token is
still the barrier against reading or acting, but the Host check makes the name
useless before that: no dashboard to frame, no API to probe for a difference
between 401 and 200, and no route where a later unauthenticated addition would
be reachable. It does not protect a token holder and it is not a substitute for
the token; it closes the one path where the browser, not the attacker, supplies
the authority.

An absent `Host` is allowed (HTTP/1.0 and some local clients omit it, and a
missing name is not one an attacker can choose). `--host 0.0.0.0` accepts only
the loopback names, so reaching a LAN bind by IP needs that address in
`--allow-host`. A proxy in front must pass a name the server knows: see the
deployment section.

### Why POST needs the token even on localhost

Loopback is not a trust boundary. Any local process can connect: a browser
extension, another user on a shared machine, a compromised dependency, a page
the browser is showing. Without the token those could stop an agent between an
edit and its commit, or `send` arbitrary text into a TUI that then runs it.
Requiring it makes an action deliberate, and there is no weaker path for
actions than for reads — the same check runs before every route.

### What a `0.0.0.0` bind exposes

With `--host 0.0.0.0 --token T`, every host that can route to this machine and
knows the token gets the dashboard and everything above: the pane tail of every
agent (`GET /api/session/<name>/pane`), the result files, the branches, the PR
URLs, and the ability to stop, type into and gc every session. The API is
`status NAME --json` and `sessions --json` verbatim, so nothing is filtered
out. A leaked token gets the agent's own shell in the worktree, by way of
`send`.

The transport is plaintext, the token included, and the cookie is not `Secure`,
so the token is readable and replayable by anyone on the path. The dashboard is
identical to the one on loopback; there is no separate "LAN mode" with extra
checks.

The ttyd terminal link does not widen this: the redirect always targets
`http://127.0.0.1:<port>` and ttyd binds loopback, so from another machine the
link resolves against the *browser's* own host and does not reach yours. Behind
a proxy it is simply a broken link unless the proxy also maps the ttyd ports.

### Deployment: TLS and auth belong to a proxy in front

This server does not terminate TLS, by design; a reverse proxy does, on the
same host, with the server left on loopback so the only plaintext hop is a
local one.

Caddy, on the machine running the dashboard:

```caddyfile
agents.example.com {
    reverse_proxy 127.0.0.1:7788
}
```

`caddy` gets a certificate for its own name and forwards `Authorization` and
`Cookie` unchanged, so the token is still checked by this server, now over TLS.
Caddy passes the incoming `Host` through unmodified, so the server has to be
told that name or the request is a 421:

```bash
spawn-freebuff-agent gui --serve --allow-host agents.example.com
```

`--allow-host` is repeatable. The form's `Origin` check keeps working, because
`Origin` and `Host` are then the same name. nginx is the same idea, with
`proxy_pass http://127.0.0.1:7788;`, `proxy_set_header Host $http_host;` (its
default is the upstream's address) and the matching `--allow-host`. Tailscale
Serve (`tailscale serve --bg 7788` with the default loopback bind) gives the
dashboard an HTTPS name inside the tailnet — pass that name to `--allow-host` —
and tailnet membership then decides who reaches it: a network control, not a
replacement for the token.

Two things a proxy does not fix. The server reads no `X-Forwarded-*` header, so
it cannot log the real client address or trust a proxy-injected identity; and
the `?token=` bootstrap URL still lands in the proxy's access log unless you
scrub query strings there. After the first request the `fb_token` cookie
carries the secret, so a stricter option is to load the page once and then
remove the token from history.

If you do bind `--host 0.0.0.0` directly instead, none of that applies: it is
plaintext on every interface, authenticated only by the token. Use it on a
single-user machine you already trust, and not on a shared network.

**What was tested.** The deviceless suite drives `gui --serve` on loopback with
curl: 401 without a token, the token as header, query and cookie, the POST
actions, `--read-only` 403 and a read-only page with no forms, the cookie path
(`403` without a nonce, `403` with a nonce and a foreign `Origin`, the
confirmation page that changes nothing, the confirm POST's `303` to `/`, and
the card reading `stopped` afterwards), the gc `303`/one-shot report, the
bearer POST without a nonce still answering `202`, the refusal of
`--host 0.0.0.0` without an explicit `--token`, the ttyd redirect, the four
security headers on `200`, `401`, `403`, `404`, `421` and `303`, a foreign
`Host` answered `421` even without a token, the loopback names and
`--allow-host` accepted, and `form-action 'self'` with the POST → `303` flow.
**Not tested:** TLS or any reverse proxy,
Tailscale, a real LAN client, and the same-site cookie case above. Those
paragraphs describe the source and the operator's job, not a tested path;
confirm them with your own proxy before relying on them.
