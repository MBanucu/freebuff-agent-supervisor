#!/usr/bin/env python3
"""Read-only HTTP server for the session inventory.

This is a thin layer over `spawn-freebuff-agent`: it reimplements no state,
it shells out to `sessions --json` and `status NAME --json` and returns what
those print. Standard library only (`http.server`), no third-party packages.

Routes:
  GET /                        dashboard, from `sessions --json`
  GET /api/sessions            `sessions --json`, verbatim
  GET /api/session/N/pane      `status N --json`, verbatim
  POST anything                403 with --read-only; actions arrive in #22

Auth: every request needs the token, compared in constant time. It is
accepted as `Authorization: Bearer ...`, as the `fb_token` cookie, or as
`?token=...` on GET so a browser can bootstrap the cookie. Without --token
the server generates one and prints it once to stderr; it is never written
to a log file.

Binding: 127.0.0.1 by default. A non-loopback address is refused unless
--token was given explicitly; binding off-loopback is for a LAN or Tailscale
and this server terminates no TLS, so put a reverse proxy in front of it.
"""

import argparse
import hmac
import http.cookies
import ipaddress
import json
import os
import re
import secrets
import socket
import subprocess
import sys
import traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, unquote, urlsplit

import render

COOKIE = "fb_token"
NAME_RE = re.compile(r"[A-Za-z0-9_-]+")
CLI_TIMEOUT = 30
TOOL = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "spawn-freebuff-agent",
)


def valid_name(name):
    """The one name validator, shared with the mutating routes in #22.

    It mirrors `valid_name` in the bash tool and is applied before a name can
    reach a filesystem path or a subprocess argument.
    """
    return bool(name) and NAME_RE.fullmatch(name) is not None


def is_loopback(host):
    if host == "localhost":
        return True
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False


class Server(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address, handler, root, token, read_only):
        super().__init__(address, handler)
        self.root = root
        self.token = token
        self.read_only = read_only


class Server6(Server):
    address_family = socket.AF_INET6


class Handler(BaseHTTPRequestHandler):
    server_version = "freebuff-gui/1"
    sys_version = ""

    # ---- transport helpers ------------------------------------------------

    def _send(self, code, body, content_type, extra=()):
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
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
        parsed = urlsplit(self.path)
        segments = [unquote(part) for part in parsed.path.split("/") if part]
        query = parse_qs(parsed.query, keep_blank_values=True)

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

        if method == "GET":
            if not segments:
                return self._dashboard(extra)
            if segments == ["api", "sessions"]:
                return self._proxy(["sessions", "--json"], 500, extra)
            # Validate the name before it can reach a path or a subprocess.
            # Take everything between the prefix and /pane so that a crafted
            # `../etc` is a 400, not a 404 that never looked at the name.
            prefix, suffix = "/api/session/", "/pane"
            if (parsed.path.startswith(prefix)
                    and parsed.path.endswith(suffix)
                    and len(parsed.path) > len(prefix) + len(suffix)):
                name = unquote(parsed.path[len(prefix):-len(suffix)])
                if not valid_name(name):
                    return self._json(400, {"error": "invalid name"}, extra=extra)
                return self._proxy(
                    ["status", name, "--json", "--no-gh"], 404, extra)
            return self._json(404, {"error": "no such route"}, extra=extra)

        # POST beyond --read-only: the mutating routes are issue #22.
        return self._json(404, {"error": "no such route"}, extra=extra)

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

    def _dashboard(self, extra):
        result = self._run(["sessions", "--json"])
        if result.returncode != 0:
            message = (result.stderr or result.stdout).decode(
                "utf-8", "replace").strip() or "sessions failed"
            self._json(500, {"error": message}, extra=extra)
            return
        try:
            sessions = json.loads(result.stdout.decode("utf-8"))
        except (UnicodeDecodeError, ValueError):
            self._json(500, {"error": "sessions --json did not parse"},
                       extra=extra)
            return
        if not isinstance(sessions, list):
            self._json(500, {"error": "sessions --json was not an array"},
                       extra=extra)
            return
        page = render.render_dashboard(
            sessions, read_only=self.server.read_only).encode("utf-8")
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
    parser.add_argument("--read-only", action="store_true",
                        help="refuse every POST with 403")
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

    generated = not args.token
    token = args.token or secrets.token_urlsafe(24)
    server_class = Server6 if ":" in args.host else Server
    try:
        httpd = server_class(
            (args.host, args.port), Handler,
            root=os.path.abspath(args.root), token=token,
            read_only=args.read_only)
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
    if generated:
        print("token=%s" % token, file=sys.stderr)
        print("generated token: shown once, pass it with --token next time",
              file=sys.stderr)

    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
