"""Render the session inventory as one self-contained HTML page.

The input is the `sessions --json` array; this module reimplements no state.
Markup is a plain card grid with inline CSS: no JavaScript, no external
assets or fonts, so the page works over `file://`, offline and behind a
strict CSP. Every value is escaped because branch names, PR URLs and result
text are arbitrary text from git and gh, not names constrained by
`valid_name`.
"""

import html
import re
from urllib.parse import quote

DASH = "&ndash;"


def _e(value):
    """Escape one value for text and attribute context."""
    if value is None or value == "":
        return DASH
    return html.escape(str(value), quote=True)


def _idle(seconds):
    if seconds is None:
        return DASH
    try:
        n = int(seconds)
    except (TypeError, ValueError):
        return _e(seconds)
    if n < 60:
        return "%ds" % n
    if n < 3600:
        return "%dm" % (n // 60)
    return "%dh%02dm" % (n // 3600, (n % 3600) // 60)


def _pr(value):
    if not value:
        return DASH
    text = _e(value)
    # Only link what a browser can safely fetch; a result file is arbitrary.
    if isinstance(value, str) and value.startswith(("http://", "https://")):
        return '<a href="%s" rel="noreferrer">%s</a>' % (text, text)
    return text


def _state_class(state):
    return re.sub(r"[^a-z0-9-]", "", str(state or "unknown").lower()) or "unknown"


def _card(session):
    name = session.get("name") or ""
    state = session.get("state") or "unknown"
    worktree = session.get("worktree") or "missing"
    worktree_class = "missing" if worktree == "missing" else "ok"
    pane = ""
    if worktree == "yes":
        pane = (
            '<a class="pane" href="/api/session/%s/pane">pane tail</a>'
            % quote(str(name), safe="")
        )
    return """
      <article class="card state-%(css)s">
        <header class="card-head">
          <h2>%(name)s</h2>
          <span class="badge">%(state)s</span>
        </header>
        <dl>
          <dt>idle</dt><dd>%(idle)s</dd>
          <dt>result</dt><dd>%(result)s</dd>
          <dt>watcher</dt><dd>%(watcher)s</dd>
          <dt>worktree</dt><dd class="%(wt_class)s">%(worktree)s</dd>
          <dt>branch</dt><dd><code>%(branch)s</code></dd>
          <dt>pr</dt><dd>%(pr)s</dd>
        </dl>
        <footer>%(pane)s</footer>
      </article>""" % {
        "css": _state_class(state),
        "name": _e(name),
        "state": _e(state),
        "idle": _idle(session.get("idle_seconds")),
        "result": _e(session.get("result")),
        "watcher": _e(session.get("watcher")),
        "wt_class": worktree_class,
        "worktree": _e(worktree),
        "branch": _e(session.get("branch")),
        "pr": _pr(session.get("pr")),
        "pane": pane,
    }


def render_dashboard(sessions, read_only=False):
    """Return the whole page for a list of `sessions --json` objects."""
    if not isinstance(sessions, list):
        sessions = []
    running = sum(1 for s in sessions if isinstance(s, dict)
                  and s.get("idle_seconds") is not None)
    count = len(sessions)
    meta = "%d session%s, %d running" % (count, "" if count == 1 else "s",
                                         running)
    badge = '\n      <span class="badge readonly">read-only</span>' if read_only else ""

    if sessions:
        body = '\n'.join(_card(s) for s in sessions if isinstance(s, dict))
        main = '<main class="cards">%s\n    </main>' % body
    else:
        main = '<main><p class="empty">no sessions</p></main>'

    return """<!DOCTYPE html>
<html lang="en">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Freebuff sessions</title>
    <style>
      :root {
        color-scheme: dark;
        --bg: #101418;
        --card: #171d23;
        --edge: #2b343d;
        --text: #d7dee6;
        --muted: #8b98a5;
        --ok: #64d08a;
        --busy: #e3b341;
        --bad: #e06c75;
        --link: #6cb6ff;
      }
      * { box-sizing: border-box; }
      body {
        margin: 0;
        padding: 1rem;
        background: var(--bg);
        color: var(--text);
        font: 15px/1.45 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
      }
      header.page {
        display: flex;
        flex-wrap: wrap;
        align-items: baseline;
        gap: 0.5rem 1rem;
        margin-bottom: 1rem;
      }
      h1 { margin: 0; font-size: 1.2rem; }
      .meta, .muted { color: var(--muted); font-size: 0.85rem; }
      .badge {
        padding: 0.1rem 0.45rem;
        border: 1px solid var(--edge);
        border-radius: 999px;
        font-size: 0.8rem;
        color: var(--muted);
      }
      .badge.readonly { color: var(--busy); }
      .cards {
        display: grid;
        grid-template-columns: repeat(auto-fill, minmax(18rem, 1fr));
        gap: 0.75rem;
      }
      .card {
        padding: 0.75rem 0.9rem;
        background: var(--card);
        border: 1px solid var(--edge);
        border-left: 4px solid var(--muted);
        border-radius: 6px;
      }
      .card.state-done, .card.state-idle { border-left-color: var(--ok); }
      .card.state-working { border-left-color: var(--busy); }
      .card.state-refused, .card.state-blocked { border-left-color: var(--bad); }
      .card-head {
        display: flex;
        align-items: center;
        justify-content: space-between;
        gap: 0.5rem;
      }
      h2 { margin: 0; font-size: 1rem; overflow-wrap: anywhere; }
      dl {
        display: grid;
        grid-template-columns: 6.5rem 1fr;
        gap: 0.15rem 0.5rem;
        margin: 0.6rem 0 0;
      }
      dt { color: var(--muted); }
      dd { margin: 0; overflow-wrap: anywhere; }
      dd.missing { color: var(--bad); }
      footer { margin-top: 0.6rem; }
      a { color: var(--link); }
      .empty { color: var(--muted); }
    </style>
  </head>
  <body>
    <header class="page">
      <h1>Freebuff sessions</h1>
      <span class="meta">%(meta)s</span>%(badge)s
    </header>
    %(main)s
  </body>
</html>
""" % {"meta": _e(meta), "badge": badge, "main": main}
