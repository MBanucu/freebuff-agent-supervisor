#!/usr/bin/env python3
"""Read-only HTTP server for the session inventory.

This is a thin layer over `spawn-freebuff-agent`: it reimplements no state,
it shells out to `sessions --json` and `status NAME --json` and returns what
those print. Standard library only (`http.server`), no third-party packages.

Routes:
  GET  /                       the page `gui --snapshot` writes
  GET  /api/sessions           `sessions --json`, verbatim
  GET  /tty/N                  302 to a ttyd viewing `tmux attach -t fb-N`
  GET  /api/session/N/pane     `status N --json`, verbatim
  POST /api/session/N/stop     `stop N`, plus `--graceful` with ?graceful=1
  POST /api/session/N/send     `send N TEXT`, text from a JSON body
  POST /api/gc                 `gc`, plus `--dry-run` with ?dry=1

Every mutating route is one CLI call: 202 with the CLI's own `key=value`
output, or 409/500 with its exit status and message. Nothing here
reimplements a decision the CLI makes, so the two cannot drift.

The served page also carries Stop / Stop (graceful) / gc forms. A form POST
is cookie-authenticated, so it must carry the per-server `form_nonce` and
must not present a foreign `Origin`, and a successful action answers 303
back to `/` (gc: to a one-shot report URL) instead of a replayable body.
Stop renders a confirmation page from the first POST and runs on the
second, so a stray click cannot end a live session. A bearer-token POST
needs no nonce, which is why curl and the CLI keep working, and
`--read-only` serves no forms and still answers every POST 403.

Auth: every request needs the token, compared in constant time. It is
accepted as `Authorization: Bearer ...`, as the `fb_token` cookie, or as
`?token=...` on GET so a browser can bootstrap the cookie. Without --token
the server generates one and prints it once to stderr; it is never written
to a log file.

Binding: 127.0.0.1 by default. A non-loopback address is refused unless
--token was given explicitly; binding off-loopback is for a LAN or Tailscale
and this server terminates no TLS, so put a reverse proxy in front of it.

Headers and Host: every response, errors and redirects included, carries
the CSP, nosniff, frame and referrer headers a `<meta>` tag cannot express
for framing, because `gui --snapshot` writes a file while this serves a
running, interactive page. A request whose `Host` is not a loopback name,
the configured `--host`, or an explicit `--allow-host` is answered 421 and
reaches no route, so a name that DNS-rebinds to 127.0.0.1 gets nothing.
"""

import argparse
import hmac
import html
import http.cookies
import ipaddress
import json
import os
import re
import secrets
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, unquote, urlsplit

COOKIE = "fb_token"
NAME_RE = re.compile(r"[A-Za-z0-9_-]+")
CLI_TIMEOUT = 30
# `send` text is a short follow-up, not a payload; the cap keeps a wrong or
# hostile Content-Length from turning a request thread into a sink.
MAX_BODY = 64 * 1024
TRUTHY = ("1", "true", "yes", "on")
# Constant strings, set on every response: the page has inline CSS and no
# script, so it needs no allowance beyond style-src. `frame-ancestors` and
# `form-action` are ignored in a `<meta>` CSP, which is why the server sends
# the policy as a header and `gui --snapshot` keeps its narrower meta for a
# file:// snapshot. connect-src 'self' stays for Chrome DevTools' own
# `/.well-known` probe, which the meta has carried since the dashboard had
# no server; without it default-src 'none' fills the console with violations.
SECURITY_HEADERS = (
    ("Content-Security-Policy",
     "default-src 'none'; style-src 'unsafe-inline'; img-src data:; "
     "connect-src 'self'; form-action 'self'; frame-ancestors 'none'; "
     "base-uri 'none'"),
    ("X-Content-Type-Options", "nosniff"),
    ("X-Frame-Options", "DENY"),
    ("Referrer-Policy", "no-referrer"),
)
# The names a request may be addressed to. A public name can resolve to
# 127.0.0.1 (DNS rebinding), and every loopback port is same-site for the
# cookie, so anything else is a 421 before auth runs.
LOOPBACK_HOSTS = ("127.0.0.1", "localhost", "::1")
# An action that redirects carries its report in memory, under a one-shot key
# in the Location, so a refresh cannot replay the POST and the report cannot
# pile up: it is taken on the next GET, expires, or is evicted oldest first.
FLASH_MAX = 20
FLASH_SECONDS = 300
TOOL = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "spawn-freebuff-agent",
)
# The one stylesheet: `gui --snapshot` inlines it, and the action pages below
# inline the same file, so a colour or a spacing value is changed in one place.
# Only the styles are shared: each page keeps its own CSP, because a file://
# snapshot carries a narrow <meta> and this server sends headers.
STYLE_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                          "page.css")
# ttyd is read-only by default: `-W` is the flag that lets a client type, so a
# viewer is read-only exactly when `-W` is absent. ttyd 1.7.x has no `-R`.
TTYD_USER = "fb"
TTYD_READY_SECONDS = 5.0
TTYD_MISSING = ("terminal links disabled: ttyd not found; "
                "install ttyd or set FREEBUFF_TTYD")


def valid_name(name):
    """The one name validator, shared by every route that takes a name.

    It mirrors `valid_name` in the bash tool and is applied before a name can
    reach a filesystem path or a subprocess argument.
    """
    return bool(name) and NAME_RE.fullmatch(name) is not None


def flag(query, key):
    """A query flag: ?key=1, ?key=true, ?key=yes or ?key=on."""
    value = (query.get(key) or [""])[0].strip().lower()
    return value in TRUTHY


def is_loopback(host):
    if host == "localhost":
        return True
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False


def host_name(raw):
    """HOST from a `Host` header, without its port, or None if malformed.

    Accepts `name[:port]` and `[v6][:port]`; a bare IPv6 literal without
    brackets is not what a browser sends and is rejected rather than guessed
    at, and a non-numeric or empty port is malformed rather than a name.
    """
    host = (raw or "").strip().lower()
    if not host:
        return None
    if host.startswith("["):
        end = host.find("]")
        if end < 0:
            return None
        name, rest = host[1:end], host[end + 1:]
        if rest and (not rest.startswith(":") or not rest[1:].isdigit()):
            return None
        return name or None
    if host.count(":") > 1:
        return None
    name, sep, port = host.partition(":")
    if sep and not port.isdigit():
        return None
    return name or None


def allowed_host_names(configured, extra=()):
    """The Host names this server answers for.

    `--host` is the address the server binds, and a proxy in front that keeps
    its own Host name is added with `--allow-host`; everything else is 421.
    """
    names = set(LOOPBACK_HOSTS)
    for value in tuple(configured) + tuple(extra):
        value = (value or "").strip().lower()
        if value.startswith("[") and value.endswith("]"):
            value = value[1:-1]
        if value:
            names.add(value)
    return frozenset(names)


def host_allowed(raw, names):
    """Whether a `Host` header is one this server answers for.

    An absent Host is allowed: HTTP/1.0 and some local clients omit it, and a
    missing name is not one a rebinding attack can supply. Everything present
    has to be a loopback literal, the bind address, or an allowed proxy name.
    """
    if not (raw or "").strip():
        return True
    return host_name(raw) in names


def ttyd_bin():
    """The ttyd executable, or None.

    `FREEBUFF_TTYD` wins over PATH, and a value that is not executable means
    "no ttyd" without falling back: that is how a test or an operator says
    the feature is unavailable on a machine that happens to have it installed.
    """
    configured = os.environ.get("FREEBUFF_TTYD")
    if configured:
        return configured if os.access(configured, os.X_OK) else None
    return shutil.which("ttyd")


def tmux_bin():
    """Like `tmux_bin` in the bash tool: FREEBUFF_TMUX, then PATH."""
    return os.environ.get("FREEBUFF_TMUX") or shutil.which("tmux")


def free_port():
    """A loopback port the kernel says is free right now.

    ttyd takes `-p 0` but never reports which port it bound, so pick one and
    let the readiness probe catch the unlikely race.
    """
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def port_open(port):
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=0.2):
            return True
    except OSError:
        return False


class Server(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address, handler, root, token, read_only, style,
                 ttyd=None, ttyd_wanted=False, interactive=False,
                 allowed_hosts=frozenset(LOOPBACK_HOSTS)):
        super().__init__(address, handler)
        self.root = root
        self.token = token
        self.style = style
        self.allowed_hosts = allowed_hosts
        self.read_only = read_only
        self.ttyd = ttyd
        self.ttyd_wanted = ttyd_wanted
        self.interactive = interactive
        # The CSRF secret, one per server process: SameSite=Strict does not
        # separate two services on 127.0.0.1 (the port is not part of the
        # site), so a form has to prove it came from this page. It dies with
        # the process, like the token, and no static snapshot ever sees it.
        self.form_nonce = secrets.token_urlsafe(24)
        # one-shot action reports: key -> (monotonic stamp, text)
        self.flashes = {}
        self.flashes_lock = threading.Lock()
        # name -> (port, process); one viewer per session, started on demand.
        self.viewers = {}
        self.viewers_lock = threading.Lock()

    def viewer(self, name):
        """(port, proc, error): the running viewer for NAME or a new one.

        One ttyd per session while its tab is open, so a second click reuses
        it instead of starting a second fleet member. `-o` makes ttyd exit
        when its single client disconnects, so a closed tab leaves nothing
        behind.
        """
        with self.viewers_lock:
            current = self.viewers.get(name)
            if current is not None and current[1].poll() is None:
                return current[0], current[1], None
            self.viewers.pop(name, None)
            tmux = tmux_bin()
            if not tmux:
                return None, None, "tmux not found; set FREEBUFF_TMUX"
            port = free_port()
            argv = [
                self.ttyd, "-p", str(port),
                # Loopback only: ttyd is never exposed beyond this host.
                "-i", "127.0.0.1",
                "-c", "%s:%s" % (TTYD_USER, self.token),
                "-o",
            ]
            if self.interactive:
                argv.append("-W")
            argv += [tmux, "attach", "-t", "fb-" + name]
            try:
                proc = subprocess.Popen(argv, stdin=subprocess.DEVNULL,
                                        stdout=subprocess.DEVNULL,
                                        stderr=subprocess.PIPE)
            except OSError as exc:
                return None, None, "cannot start ttyd: %s" % exc
            error = self._wait_listening(proc, port)
            if error:
                return None, None, error
            self.viewers[name] = (port, proc)
            return port, proc, None

    @staticmethod
    def _wait_listening(proc, port):
        deadline = time.monotonic() + TTYD_READY_SECONDS
        while time.monotonic() < deadline:
            if proc.poll() is not None:
                try:
                    message = proc.stderr.read().decode("utf-8", "replace")
                except (OSError, ValueError):
                    message = ""
                proc.stderr.close()
                message = message.strip() or "status %d" % proc.returncode
                return "ttyd exited: %s" % message
            if port_open(port):
                return None
            time.sleep(0.05)
        proc.terminate()
        return "ttyd did not listen on 127.0.0.1:%d" % port

    def remember_flash(self, text):
        """Store an action's output and return the key that redirects to it."""
        key = secrets.token_urlsafe(16)
        now = time.monotonic()
        with self.flashes_lock:
            for stale, (stamp, _) in list(self.flashes.items()):
                if now - stamp > FLASH_SECONDS:
                    del self.flashes[stale]
            while len(self.flashes) >= FLASH_MAX:
                del self.flashes[next(iter(self.flashes))]
            self.flashes[key] = (now, text)
        return key

    def take_flash(self, key):
        """The stored report for KEY, consumed once; empty when unknown."""
        with self.flashes_lock:
            item = self.flashes.pop(key, None)
        return item[1] if item else ""

    def shutdown_viewers(self):
        with self.viewers_lock:
            viewers, self.viewers = self.viewers, {}
        for _, proc in viewers.values():
            if proc.poll() is None:
                proc.terminate()
        for _, proc in viewers.values():
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()


class Server6(Server):
    address_family = socket.AF_INET6


class Handler(BaseHTTPRequestHandler):
    server_version = "freebuff-gui/1"
    sys_version = ""

    # The body is read at most once: a form POST and a JSON body both go
    # through it, and the stream cannot be rewound.
    _body_cache = None

    # ---- transport helpers ------------------------------------------------

    def end_headers(self):
        """Attach the security headers to every response.

        Placed here rather than in `_send` so the error paths this handler
        does not build (a malformed request line answered by the base class)
        carry them too, and so a new `_send` caller cannot forget one.
        """
        for key, value in SECURITY_HEADERS:
            self.send_header(key, value)
        super().end_headers()

    def _send(self, code, body, content_type, extra=()):
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        for key, value in extra:
            self.send_header(key, value)
        self.end_headers()
        if self.command != "HEAD":
            try:
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError):
                pass

    def _json(self, code, payload, extra=()):
        body = (json.dumps(payload) + "\n").encode("utf-8")
        self._send(code, body, "application/json", extra)

    def _redirect(self, location, extra=()):
        """303 after a form action: the browser follows with a GET.

        A POST that renders its result is replayable by a refresh; a redirect
        is not, and the action has already happened exactly once.
        """
        self._send(303, b"", "text/plain; charset=utf-8",
                   extra + [("Location", location)])

    def _page(self, code, title, body, extra=()):
        """A small server-rendered page, for a form's answer.

        This is the second markup, not a second stylesheet: the CSS is
        gui/page.css, the same file `gui --snapshot` inlines into the
        dashboard, so both pages share one palette and dark mode. Only the
        layout differs (a heading, a sentence, one form); no script, no
        external assets, and the page keeps its own narrow CSP because the
        dashboard's policy arrives as an HTTP header.
        """
        page = (
            "<!DOCTYPE html>\n<html lang=\"en\"><head><meta charset=\"utf-8\">\n"
            "<meta name=\"viewport\" content=\"width=device-width, "
            "initial-scale=1\">\n"
            "<meta http-equiv=\"Content-Security-Policy\" "
            "content=\"default-src 'none'; style-src 'unsafe-inline'\">\n"
            "<meta name=\"referrer\" content=\"no-referrer\">\n"
            "<title>%s</title>\n<style>\n%s</style>\n</head>\n<body>\n"
            "<main class=\"action-page\">\n%s\n</main>\n"
            "</body></html>\n"
        ) % (html.escape(title), self.server.style, body)
        self._send(code, page.encode("utf-8"), "text/html; charset=utf-8",
                   extra)

    def log_message(self, fmt, *args):
        # The request line may carry ?token=; log only the path.
        if self.requestline:
            try:
                path = urlsplit(self.path).path
            except ValueError:
                path = ""
            sys.stderr.write("%s %s %s\n" % (
                self.address_string(), self.command, path))
        else:
            sys.stderr.write((fmt % args) + "\n")

    # ---- auth -------------------------------------------------------------

    def _form_token(self):
        header = self.headers.get("Authorization", "")
        if header.startswith("Bearer "):
            return header[len("Bearer "):].strip(), "header"
        raw = self.headers.get("Cookie")
        if raw:
            jar = http.cookies.SimpleCookie()
            try:
                jar.load(raw)
            except http.cookies.CookieError:
                jar = {}
            morsel = jar.get(COOKIE) if jar else None
            if morsel is not None:
                return morsel.value, "cookie"
        return "", ""

    def _cookie_header(self):
        jar = http.cookies.SimpleCookie()
        jar[COOKIE] = self.server.token
        jar[COOKIE]["path"] = "/"
        jar[COOKIE]["httponly"] = True
        jar[COOKIE]["samesite"] = "Strict"
        return "Set-Cookie", jar.output(header="").strip()

    # ---- dispatch ---------------------------------------------------------

    def do_GET(self):
        self._handle("GET")

    def do_HEAD(self):
        self._handle("GET")

    def do_POST(self):
        self._handle("POST")

    def _handle(self, method):
        try:
            self._route(method)
        except Exception:
            traceback.print_exc()
            self._json(500, {"error": "internal error"})

    def _route(self, method):
        self._body_cache = None
        parsed = urlsplit(self.path)
        segments = [unquote(part) for part in parsed.path.split("/") if part]
        query = parse_qs(parsed.query, keep_blank_values=True)

        # Host first, before auth and before any route: a name that resolves
        # to loopback by DNS rebinding would otherwise reach the dashboard
        # with the browser's cookie. 421 Misdirected Request is the answer
        # for an authority this server does not serve, and it carries the
        # same headers as every other response.
        if not host_allowed(self.headers.get("Host", ""),
                            self.server.allowed_hosts):
            return self._json(421, {"error": "misdirected request"})

        # Chrome DevTools fetches this from the page's origin for its
        # workspace feature. Answering 204 keeps the console free of errors;
        # the real payload is a file list, which this server never exposes, so
        # the endpoint stays empty and needs no token.
        if segments == [".well-known", "appspecific", "com.chrome.devtools.json"]:
            return self._send(204, "", "application/json", [])

        provided, source = self._form_token()
        if not provided and method == "GET":
            provided = (query.get("token") or [""])[0]
            source = "query" if provided else ""

        if not hmac.compare_digest(provided.encode("utf-8"),
                                   self.server.token.encode("utf-8")):
            self._json(
                401,
                {"error": "unauthorized"},
                extra=[("WWW-Authenticate", 'Bearer realm="freebuff"')],
            )
            return

        extra = []
        if source == "query":
            # Lets a browser exchange ?token= for the cookie once, so pane
            # links and later requests need no token in the URL.
            extra.append(self._cookie_header())

        if method == "POST" and self.server.read_only:
            self._json(403, {"error": "read-only: mutating routes are disabled"},
                       extra=extra)
            return

        # A form POST is cookie-authenticated, so the cookie alone is not
        # proof the request came from a page this server rendered: another
        # service on 127.0.0.1 is same-site and could send it. The nonce
        # says the form came from here, and Origin says the browser did too.
        # A bearer-token caller already had to read the secret and keeps the
        # nonce-free path curl and the CLI tests rely on.
        fields, form = {}, False
        if method == "POST":
            if not self._same_origin():
                self._json(403, {"error": "cross-origin POST refused"},
                           extra=extra)
                return
            parsed_fields = self._form_fields()
            if parsed_fields is None:
                return
            fields = parsed_fields
            nonce = fields.get("nonce", "")
            form = bool(nonce) and hmac.compare_digest(
                nonce.encode("utf-8"), self.server.form_nonce.encode("utf-8"))
            if source == "cookie" and not form:
                self._json(
                    403,
                    {"error": "missing or invalid form nonce; reload the page"},
                    extra=extra)
                return

        if method == "GET":
            if not segments:
                # The gc report from a redirect is taken once, so a refresh
                # shows the plain dashboard instead of replaying it.
                key = (query.get("gc") or [""])[0]
                return self._dashboard(
                    extra, self.server.take_flash(key) if key else "")
            if segments == ["api", "sessions"]:
                return self._proxy(["sessions", "--json"], 500, extra)
            # /tty/<name>: the dashboard's terminal link. The name is
            # unquoted already, so valid_name runs before anything else.
            if len(segments) == 2 and segments[0] == "tty":
                return self._terminal(segments[1], extra)
            # Validate the name before it can reach a path or a subprocess.
            # Take everything between the prefix and /pane so that a crafted
            # `../etc` is a 400, not a 404 that never looked at the name.
            name = self._name_from(parsed.path, "/pane")
            if name is not None:
                if not valid_name(name):
                    return self._json(400, {"error": "invalid name"}, extra=extra)
                return self._proxy(
                    ["status", name, "--json", "--no-gh"], 404, extra)
            return self._json(404, {"error": "no such route"}, extra=extra)

        return self._post(parsed, query, extra, form)

    def _post(self, parsed, query, extra, form=False):
        """The mutating routes, each one a single CLI call.

        `stop`, `send` and `gc` stay the only place that knows what those
        actions do, so an action answers with their `key=value` lines and
        their exit status instead of a second result vocabulary.
        """
        if parsed.path == "/api/gc":
            argv = ["gc"]
            if flag(query, "dry"):
                argv.append("--dry-run")
            # The report is the point of the dry run, and a redirect cannot
            # carry a body, so it travels under a one-shot key.
            return self._action(argv, extra, form, flash=form)

        for suffix, action in (("/stop", "stop"), ("/send", "send")):
            name = self._name_from(parsed.path, suffix)
            if name is None:
                continue
            if not valid_name(name):
                return self._json(400, {"error": "invalid name"}, extra=extra)
            if not self._known(name):
                return self._json(404, {"error": "unknown session"}, extra=extra)
            if action == "stop":
                argv = ["stop", name]
                graceful = flag(query, "graceful")
                if graceful:
                    argv.append("--graceful")
                # One click prepares the stop, the second performs it: a
                # stray click on a card cannot end a live session.
                if form and not flag(query, "confirm"):
                    return self._confirm_stop(name, graceful, extra)
                return self._action(argv, extra, form)
            # `send` takes its text from the body only: a URL is logged, and a
            # pane command belongs in a request that has to be sent on purpose.
            text = self._send_text()
            if text is None:
                return  # _send_text already answered the request
            return self._action(["send", name, text], extra)

        return self._json(404, {"error": "no such route"}, extra=extra)

    def _confirm_stop(self, name, graceful, extra):
        """The second click before a stop: render it, run nothing.

        Nothing has happened when this page is drawn, so a click on a card's
        Stop costs nothing. The confirm form is the only POST that reaches
        `stop`, and it carries the same nonce.
        """
        action = "/api/session/%s/stop?confirm=1" % name
        effect = "This ends the tmux session immediately."
        if graceful:
            action = "/api/session/%s/stop?graceful=1&confirm=1" % name
            effect = ("This ends the turn first and stops the session once "
                      "the pane is no longer working.")
        page = (
            "<h1>Stop fb-%s?</h1>\n"
            "<p>%s The worktree and branch stay.</p>\n"
            "<form method=\"post\" action=\"%s\">"
            "<input type=\"hidden\" name=\"nonce\" value=\"%s\">"
            "<button type=\"submit\">Yes, stop fb-%s</button></form>\n"
            "<p><a href=\"/\">cancel</a></p>\n"
        ) % (html.escape(name), effect, html.escape(action),
             html.escape(self.server.form_nonce), html.escape(name))
        self._page(200, "confirm stop", page, extra)

    def _name_from(self, path, suffix):
        """NAME from /api/session/NAME/SUFFIX, or None for another route.

        Everything between the fixed prefix and the suffix is the name, so a
        crafted `../etc` is rejected by valid_name instead of matching no
        route at all.
        """
        prefix = "/api/session/"
        if (path.startswith(prefix) and path.endswith(suffix)
                and len(path) > len(prefix) + len(suffix)):
            return unquote(path[len(prefix):-len(suffix)])
        return None

    def _terminal(self, name, extra):
        """Answer the terminal link by starting (or reusing) a ttyd viewer.

        The browser is redirected to the viewer's own loopback URL; the ttyd
        port carries basic auth derived from this server's token, so the
        redirect never exposes an unauthenticated terminal.
        """
        if not valid_name(name):
            return self._json(400, {"error": "invalid name"}, extra=extra)
        if not self.server.ttyd:
            return self._json(503, {"error": TTYD_MISSING}, extra=extra)
        if not self._known(name):
            return self._json(404, {"error": "unknown session"}, extra=extra)
        if not self._running(name):
            return self._json(
                409, {"error": "fb-%s is not running" % name}, extra=extra)
        port, _, error = self.server.viewer(name)
        if error:
            return self._json(500, {"error": error}, extra=extra)
        self._send(302, b"", "text/plain; charset=utf-8",
                   extra=extra + [("Location", "http://127.0.0.1:%d/" % port)])

    def _running(self, name):
        tmux = tmux_bin()
        if not tmux:
            return False
        try:
            result = subprocess.run([tmux, "has-session", "-t", "fb-" + name],
                                    capture_output=True, timeout=CLI_TIMEOUT)
        except (OSError, subprocess.TimeoutExpired):
            return False
        return result.returncode == 0

    def _known(self, name):
        """Whether the inventory knows this name: its worktree exists.

        `stop` on a name with no session prints `stopped=no` and exits 0, so
        an unknown name has to be answered here or the browser would read a
        no-op as success. This is the pane route's 404 rule, applied to the
        actions.
        """
        return os.path.isdir(os.path.join(self.server.root, ".worktrees", name))

    def _read_body(self):
        """The request body, read once, or None after answering an error."""
        if self._body_cache is not None:
            return self._body_cache
        raw_length = self.headers.get("Content-Length")
        try:
            length = int(raw_length) if raw_length else 0
        except ValueError:
            length = -1
        if length < 0:
            self._json(400, {"error": "invalid Content-Length"})
            return None
        if length > MAX_BODY:
            self._json(413, {"error": "body too large"})
            return None
        self._body_cache = self.rfile.read(length) if length else b""
        return self._body_cache

    def _form_fields(self):
        """The fields of a URL-encoded form POST, or None after an error.

        That is the only encoding a browser produces without JavaScript, so
        the JSON body `send` takes never comes through here.
        """
        ctype = (self.headers.get("Content-Type") or "").split(";")[0]
        if ctype.strip().lower() != "application/x-www-form-urlencoded":
            return {}
        raw = self._read_body()
        if raw is None:
            return None
        try:
            text = raw.decode("utf-8")
        except UnicodeDecodeError:
            return {}
        return {key: value[0] for key, value in
                parse_qs(text, keep_blank_values=True).items()}

    def _same_origin(self):
        """Whether a POST's Origin, when sent, is this server's own origin.

        No Origin means a non-browser caller (curl, the CLI) and is allowed;
        a browser sends it, so a page on another port of 127.0.0.1 — the
        same site for cookies — cannot post here as the logged-in user. The
        scheme is ignored because a TLS proxy terminates https in front and
        this server still sees its own Host.
        """
        origin = self.headers.get("Origin")
        if not origin:
            return True
        try:
            parsed = urlsplit(origin)
        except ValueError:
            return False
        host = (self.headers.get("Host") or "").strip()
        if not parsed.netloc or not host:
            return False
        return parsed.netloc.lower() == host.lower()

    def _send_text(self):
        """The text for `send`, or None after answering the request."""
        raw = self._read_body()
        if raw is None:
            return None
        try:
            payload = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, ValueError):
            self._json(400, {"error": "body must be JSON"})
            return None
        text = payload.get("text") if isinstance(payload, dict) else None
        if not isinstance(text, str) or not text.strip():
            self._json(400, {"error": "body needs a non-empty text string"})
            return None
        return text

    def _action(self, argv, extra, form=False, flash=False):
        """Run one mutating CLI command and return what it printed.

        For a non-form caller: 202 with the CLI's `key=value` lines when it
        succeeded. For a form submission: 303 back to the dashboard, with the
        output stashed under a one-shot key when FLASH is set (gc's report),
        so a refresh cannot replay the POST. On failure the CLI's own message,
        with its exit status as the HTTP status: 1 means the session was in
        the wrong state (a graceful stop that is still working, a send to a
        session that is gone), anything else is a server fault. The browser
        can then tell "stopped" from "still busy" without a second result
        vocabulary.
        """
        result = self._run(argv)
        if result.returncode == 0:
            if flash:
                key = self.server.remember_flash(
                    result.stdout.decode("utf-8", "replace"))
                self._redirect("/?gc=" + key, extra)
                return
            if form:
                self._redirect("/", extra)
                return
            self._send(202, result.stdout, "text/plain; charset=utf-8", extra)
            return
        body = result.stdout + result.stderr
        if not body.strip():
            body = ("command failed with status %d\n"
                    % result.returncode).encode("utf-8")
        status = 409 if result.returncode == 1 else 500
        if form or flash:
            page = ("<h1>action failed</h1>\n<pre>%s</pre>\n"
                    "<p><a href=\"/\">back to the dashboard</a></p>\n"
                    % html.escape(body.decode("utf-8", "replace")))
            self._page(status, "action failed", page, extra)
            return
        self._send(status, body, "text/plain; charset=utf-8", extra)

    # ---- routes -----------------------------------------------------------

    def _run(self, argv):
        cmd = ["bash", TOOL, "--root", self.server.root] + argv
        return subprocess.run(cmd, capture_output=True, timeout=CLI_TIMEOUT)

    def _proxy(self, argv, failure_status, extra):
        result = self._run(argv)
        if result.returncode != 0:
            message = (result.stderr or result.stdout).decode(
                "utf-8", "replace").strip() or "command failed"
            self._json(failure_status, {"error": message}, extra=extra)
            return
        self._send(200, result.stdout, "application/json", extra)

    def _dashboard(self, extra, flash_text=""):
        # Reuse the snapshot renderer instead of keeping a second markup: the
        # page the browser gets is byte-for-byte what `gui --snapshot` writes.
        with tempfile.TemporaryDirectory(prefix="freebuff-gui-") as tmp:
            path = os.path.join(tmp, "dashboard.html")
            argv = ["gui", "--snapshot", path]
            if self.server.ttyd:
                # The renderer owns the markup; it only has to know that a
                # terminal link exists and where it points.
                argv.append("--terminal-links")
            elif self.server.ttyd_wanted:
                argv += ["--terminal-note", TTYD_MISSING]
            # Read-only serves no forms at all, so a reader never gets a
            # button whose only outcome is a 403.
            if not self.server.read_only:
                argv += ["--form-nonce", self.server.form_nonce]
            if flash_text:
                flash_path = os.path.join(tmp, "flash.txt")
                with open(flash_path, "w", encoding="utf-8") as handle:
                    handle.write(flash_text)
                argv += ["--flash-file", flash_path]
            result = self._run(argv)
            if result.returncode != 0:
                message = (result.stderr or result.stdout).decode(
                    "utf-8", "replace").strip() or "snapshot failed"
                self._json(500, {"error": message}, extra=extra)
                return
            try:
                with open(path, "rb") as handle:
                    page = handle.read()
            except OSError as exc:
                self._json(500, {"error": "dashboard: %s" % exc}, extra=extra)
                return
        self._send(200, page, "text/html; charset=utf-8", extra)


def parse_args(argv):
    parser = argparse.ArgumentParser(
        prog="spawn-freebuff-agent gui --serve",
        description="Read-only HTTP dashboard over the session inventory.",
    )
    parser.add_argument("--root", default=os.getcwd(),
                        help="repository root (default: current directory)")
    parser.add_argument("--host", default="127.0.0.1",
                        help="bind address (default: 127.0.0.1)")
    parser.add_argument("--port", type=int, default=7788,
                        help="bind port, 0 for an ephemeral one (default: 7788)")
    parser.add_argument("--token", default=None,
                        help="bearer token; generated and printed once if omitted")
    parser.add_argument("--allow-host", action="append", default=[],
                        metavar="NAME",
                        help="extra Host name to answer, repeatable; for a "
                             "reverse proxy that keeps its own name")
    parser.add_argument("--read-only", action="store_true",
                        help="refuse every POST with 403")
    parser.add_argument("--ttyd", action="store_true",
                        help="add a terminal link per session, served by ttyd")
    parser.add_argument("--interactive", action="store_true",
                        help="let the ttyd viewer type (needs --ttyd)")
    return parser.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)
    if not 0 <= args.port <= 65535:
        print("gui: --port must be between 0 and 65535", file=sys.stderr)
        return 2
    if not is_loopback(args.host) and not args.token:
        print("gui: refusing to bind %s without --token; use --token or the "
              "default --host 127.0.0.1" % args.host, file=sys.stderr)
        return 2
    if not os.path.isfile(TOOL):
        print("gui: missing %s" % TOOL, file=sys.stderr)
        return 2
    try:
        with open(STYLE_FILE, encoding="utf-8") as handle:
            style = handle.read()
    except OSError as exc:
        print("gui: cannot read the shared stylesheet %s: %s"
              % (STYLE_FILE, exc), file=sys.stderr)
        return 2
    if args.interactive and not args.ttyd:
        print("gui: --interactive needs --ttyd", file=sys.stderr)
        return 2
    if args.interactive and args.read_only:
        print("gui: --interactive cannot be combined with --read-only: a "
              "read-only server must not offer a writable terminal",
              file=sys.stderr)
        return 2
    # Missing ttyd is not fatal: the dashboard renders without terminal
    # links and says why, instead of failing the whole server.
    ttyd = ttyd_bin() if args.ttyd else None

    generated = not args.token
    token = args.token or secrets.token_urlsafe(24)
    server_class = Server6 if ":" in args.host else Server
    allowed = allowed_host_names([args.host], args.allow_host)
    try:
        httpd = server_class(
            (args.host, args.port), Handler,
            root=os.path.abspath(args.root), token=token,
            read_only=args.read_only, style=style, ttyd=ttyd,
            ttyd_wanted=args.ttyd, interactive=args.interactive,
            allowed_hosts=allowed)
    except OSError as exc:
        print("gui: cannot listen on %s:%s: %s" % (args.host, args.port, exc),
              file=sys.stderr)
        return 2

    shown = "[%s]" % args.host if ":" in args.host else args.host
    # Flush: a caller redirecting stdout to a file must see these before the
    # server starts serving.
    print("listening=http://%s:%d" % (shown, httpd.server_address[1]),
          flush=True)
    print("root=%s" % os.path.abspath(args.root), flush=True)
    print("read_only=%s" % ("yes" if args.read_only else "no"), flush=True)
    if args.ttyd:
        print("ttyd=%s" % ("yes" if ttyd else "missing"), flush=True)
        if ttyd:
            print("ttyd_path=%s" % ttyd, flush=True)
            print("interactive=%s" % ("yes" if args.interactive else "no"),
                  flush=True)
        else:
            print("note=%s" % TTYD_MISSING, flush=True)
    if generated:
        print("token=%s" % token, file=sys.stderr)
        print("generated token: shown once, pass it with --token next time",
              file=sys.stderr)

    # A viewer is a child process, so a SIGTERM (a supervisor stopping the
    # server) has to unwind through the cleanup below instead of exiting
    # outright and leaving ttyd behind.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))

    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.shutdown_viewers()
        httpd.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
