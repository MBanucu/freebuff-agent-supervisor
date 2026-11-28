# ---- the GUI ----
# The static snapshot and the served page, both over `sessions --json`.
snapshot_html() {
    # snapshot_html FILE JSON WATCH [LINK_PREFIX] [NOTE] [FORM_NONCE] [FLASH]
    # -> one self-contained page. `sessions --json` is the input: fixed keys,
    # one per line, so the reader below is a field scan rather than a general
    # JSON parser. WATCH is empty for a one shot snapshot and a whole number of
    # seconds for the meta refresh. LINK_PREFIX is `/tty/` when the served page
    # should carry a terminal link per session; NOTE is one line under the
    # header. FORM_NONCE adds the action forms and is empty for a static
    # snapshot, which stays read-only; FLASH is the output of an action that
    # redirected here (the gc report) and is shown above the cards.
    # The CSS is inlined from gui/page.css, shared with gui/server.py's action
    # pages, so the page stays a single file with no external asset.
    local file="$1" json="$2" watch="$3" link_prefix=${4:-} note_text=${5:-}
    local form_nonce=${6:-} flash_text=${7:-}
    local line key value name state idle watcher worktree result branch pr
    local model_name model_hours in_model=0
    local tests="" commit="" wt generated total=0 live=0 trees=0 cards='' card
    local cls pr_html refresh='' css_file
    css_file=$(stylesheet_file)
    [ -f "$css_file" ] ||
        die "gui: missing $css_file (the shared stylesheet next to the tool)"
    generated=$(date -u '+%Y-%m-%d %H:%M:%SZ')
    if [ -n "$watch" ]; then
        refresh="<meta http-equiv=\"refresh\" content=\"$watch\">"
    fi

    while IFS= read -r line; do
        case "$line" in
            '  {'*)
                name='' state='' idle='' watcher='' worktree='' result=''
                branch='' pr='' model_name='' model_hours='' in_model=0
                continue
                ;;
            '  }'*)
                total=$((total + 1))
                [ "$worktree" = yes ] && trees=$((trees + 1))
                [ -n "$idle" ] && live=$((live + 1))
                tests=''
                commit=''
                if [ "$worktree" = yes ] && valid_name "$name"; then
                    wt="$ROOT/.worktrees/$name"
                    if [ -f "$wt/$RESULT_FILE" ]; then
                        tests=$(result_key "$wt/$RESULT_FILE" tests)
                        commit=$(result_key "$wt/$RESULT_FILE" commit)
                    fi
                    if [ -z "$commit" ]; then
                        commit=$(git -C "$wt" log -1 --format='%h %s' \
                            2>/dev/null || true)
                    fi
                fi
                cls=$(state_class "$state")
                card="<article class=\"card state-$cls\">"$'\n'
                card+="<header><h2>$(html_escape "$name")</h2>"
                if [ "$worktree" != yes ]; then
                    card+="<span class=\"tag\">no worktree</span>"
                fi
                card+="<span class=\"badge\">"
                card+="$(html_escape "${state:-unknown}")</span></header>"$'\n'
                card+="<dl>"$'\n'
                if [ -n "$idle" ]; then
                    card+="<dt>idle</dt><dd>${idle}s</dd>"$'\n'
                fi
                card+="<dt>watcher</dt><dd>$(html_escape "${watcher:--}")</dd>"$'\n'
                card+="<dt>worktree</dt><dd>$(html_escape "$worktree")</dd>"$'\n'
                card+="<dt>result</dt><dd>$(html_escape "${result:--}")</dd>"$'\n'
                card+="<dt>branch</dt><dd><code>$(html_escape "${branch:--}")</code></dd>"$'\n'
                # The model and its cost class are one row, so `free` and
                # `2x` are visible at a glance next to the hours reading (#136).
                if [ -n "$model_name" ]; then
                    card+="<dt>model</dt><dd>$(html_escape "$model_name")"
                    card+=" <span class=\"tag\">"
                    card+="$(html_escape "$model_hours")</span></dd>"$'\n'
                fi
                # A terminal link exists only for a served page with ttyd
                # behind it, and only for a name the tool accepts.
                if [ -n "$link_prefix" ] && [ "$worktree" = yes ] &&
                    valid_name "$name"; then
                    card+="<dt>terminal</dt><dd><a href=\"$(html_escape "$link_prefix$name")\">open in ttyd</a></dd>"$'\n'
                fi
                if [ -n "$pr" ]; then
                    case "$pr" in
                        http://*|https://*)
                            pr_html="<a href=\"$(html_escape "$pr")\">"
                            pr_html+=$(html_escape "$pr")
                            pr_html+='</a>'
                            ;;
                        *) pr_html=$(html_escape "$pr") ;;
                    esac
                else
                    pr_html='-'
                fi
                card+="<dt>pr</dt><dd>$pr_html</dd>"$'\n'
                if [ -n "$commit" ]; then
                    card+="<dt>commit</dt><dd><code>$(html_escape "$commit")</code></dd>"$'\n'
                fi
                if [ -n "$tests" ]; then
                    card+="<dt>tests</dt><dd>$(html_escape "$tests")</dd>"$'\n'
                fi
                card+='</dl>'$'\n'
                # Actions only for a running session the action could end.
                # `done` and `blocked` are result states: the session is
                # already over, so a Stop button would be a lie.
                if [ -n "$form_nonce" ] && [ "$worktree" = yes ] &&
                    valid_name "$name" && [ -n "$idle" ]; then
                    case "${state:-}" in
                        done|stopped|failed|blocked) ;;
                        *)
                            card+='<div class="actions">'
                            card+=$(action_form "$form_nonce" \
                                "/api/session/$name/stop" 'Stop')
                            card+=$(action_form "$form_nonce" \
                                "/api/session/$name/stop?graceful=1" \
                                'Stop (graceful)')
                            card+='</div>'$'\n'
                            ;;
                    esac
                fi
                card+='</article>'$'\n'
                cards+=$card
                continue
                ;;
            '    "model": {'*)
                in_model=1
                continue
                ;;
            # The model object is the only nested one the card reads; its
            # closing brace ends the read so the account hours object below it
            # is not mistaken for the model's own hours.
            '    }'*)
                in_model=0
                continue
                ;;
            '      "name": '*)
                [ "$in_model" = 1 ] || continue
                value=${line#*: }
                value=${value%,}
                model_name=$(json_scalar "$value")
                continue
                ;;
            '      "hours": '*)
                [ "$in_model" = 1 ] || continue
                value=${line#*: }
                value=${value%,}
                model_hours=$(json_scalar "$value")
                continue
                ;;
            '    "'*) ;;
            *) continue ;;
        esac
        key=${line#    \"}
        key=${key%%\"*}
        value=${line#*: }
        value=${value%,}
        value=$(json_scalar "$value")
        case "$key" in
            name) name=$value ;;
            state) state=$value ;;
            idle_seconds) idle=$value ;;
            watcher) watcher=$value ;;
            worktree) worktree=$value ;;
            result) result=$value ;;
            branch) branch=$value ;;
            pr) pr=$value ;;
        esac
    done <<<"$json"

    {
        printf '<!DOCTYPE html>\n'
        printf '<html lang="en">\n<head>\n'
        printf '<meta charset="utf-8">\n'
        printf '<meta name="viewport" content="width=device-width, initial-scale=1">\n'
        # connect-src 'self' is here for Chrome DevTools, which fetches
        # /.well-known/appspecific/com.chrome.devtools.json from the page's
        # origin; without it the probe is blocked and the console shows two
        # violations per load. Same origin only, and there is no script to
        # use the allowance anyway.
        printf '<meta http-equiv="Content-Security-Policy" content="default-src %s; style-src %s; img-src data:; connect-src %s">\n' \
            "'none'" "'unsafe-inline'" "'self'"
        printf '<meta name="referrer" content="no-referrer">\n'
        [ -z "$refresh" ] || printf '%s\n' "$refresh"
        printf '<title>freebuff agents</title>\n'
        printf '<style>\n'
        cat "$css_file"
        printf '</style>\n</head>\n<body>\n'
        printf '<header class="page">\n<h1>freebuff agents</h1>\n'
        printf '<p class="meta">repo %s · generated %s · sessions %s · running %s · worktrees %s · orphans %s</p>\n' \
            "$(html_escape "$ROOT")" "$generated" "$total" "$live" \
            "$trees" "$((total - trees))"
        if [ -n "$note_text" ]; then
            printf '<p class="note">%s</p>\n' "$(html_escape "$note_text")"
        fi
        # The safe action comes first: a dry run reports, it does not stop
        # anything, and its report is useful without a terminal. Nothing to
        # reap means no form.
        if [ -n "$form_nonce" ] && [ "$live" -gt 0 ]; then
            printf '<div class="actions">%s</div>\n' \
                "$(action_form "$form_nonce" '/api/gc?dry=1' 'gc --dry-run')"
        fi
        printf '</header>\n'
        if [ -n "$flash_text" ]; then
            printf '<section class="flash">\n<h2>gc --dry-run</h2>\n<pre>%s</pre>\n</section>\n' \
                "$(html_escape "$flash_text")"
        fi
        printf '<main class="grid">\n'
        if [ "$total" = 0 ]; then
            printf '<p class="empty">no sessions</p>\n'
        else
            printf '%s' "$cards"
        fi
        printf '</main>\n'
        if [ -n "$form_nonce" ]; then
            printf '<footer>Actions are plain server-rendered forms; no script. Stop asks for confirmation before it acts.</footer>\n'
        else
            printf '<footer>Read-only view from spawn-freebuff-agent sessions --json. No script.</footer>\n'
        fi
        printf '</body>\n</html>\n'
    } >"$file.tmp.$$"
    mv "$file.tmp.$$" "$file"
}

gui() {
    # Two modes over the same inventory:
    #   --snapshot FILE [--watch N] [--no-gh]      write one page
    #   --serve [--port N] [--host H] [--token T]  serve that page and the API
    # The server itself is gui/server.py; python3 stays optional so the rest
    # of the CLI works on a host that does not have it.
    local snapshot='' watch='' no_gh=0 serve=0 first=1 json args py dir
    local links='' note_text='' ttyd=0 interactive=0 source=pane
    local form_nonce='' flash_file='' flash_text=''
    local passthrough=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --snapshot) snapshot=${2:-}; shift 2 ;;
            --watch) watch=${2:-}; shift 2 ;;
            --no-gh) no_gh=1; shift ;;
            --serve) serve=1; shift ;;
            --ttyd) ttyd=1; passthrough+=(--ttyd); shift ;;
            --interactive) interactive=1; passthrough+=(--interactive); shift ;;
            --source) source=${2:-}; passthrough+=(--source "${2:-}"); shift 2 ;;
            --terminal-links) links=/tty/; shift ;;
            --terminal-note) note_text=${2:-}; shift 2 ;;
            --form-nonce) form_nonce=${2:-}; shift 2 ;;
            --flash-file) flash_file=${2:-}; shift 2 ;;
            --port|--host|--token|--allow-host)
                [ $# -ge 2 ] || die "gui: $1 needs a value"
                passthrough+=("$1" "$2"); shift 2 ;;
            --read-only) passthrough+=(--read-only); shift ;;
            -h|--help) usage; exit 0 ;;
            *) die "gui: unsupported argument: $1" ;;
        esac
    done
    case "$source" in
        pane|log|concord|auto) ;;
        *) die "gui: --source must be pane, log, concord or auto" ;;
    esac

    if [ "$serve" = 0 ] && { [ "$ttyd" = 1 ] || [ "$interactive" = 1 ]; }; then
        die "gui: --ttyd and --interactive belong to --serve"
    fi

    if [ "$serve" = 1 ]; then
        [ -z "$snapshot" ] ||
            die "gui: --serve and --snapshot are separate modes"
        py=$(command -v python3 2>/dev/null || true)
        [ -n "$py" ] ||
            die "gui: --serve needs python3 (pkg install python on Termux); the rest of the CLI works without it"
        case "$0" in
            */*) dir=$(cd "$(dirname "$0")" && pwd) ;;
            *) dir=$(cd "$(dirname "$(command -v "$0" 2>/dev/null || printf '%s' "$0")")" && pwd) ;;
        esac
        [ -f "$dir/gui/server.py" ] ||
            die "gui: gui/server.py is missing next to the tool"
        exec "$py" "$dir/gui/server.py" --root "$ROOT" \
            ${passthrough[@]+"${passthrough[@]}"}
    fi

    [ -n "$snapshot" ] || die "gui: --snapshot FILE or --serve is required"
    if [ -n "$watch" ]; then
        is_num "$watch" || die "gui: --watch must be a number"
        [ "$watch" -ge 1 ] || die "gui: --watch must be at least 1 second"
    fi
    mkdir -p "$(dirname "$snapshot")"
    while :; do
        args=(--json --source "$source")
        if [ "$no_gh" = 1 ]; then
            args+=(--no-gh)
        fi
        json=$(sessions "${args[@]}")
        flash_text=''
        if [ -n "$flash_file" ] && [ -f "$flash_file" ]; then
            flash_text=$(cat "$flash_file")
        fi
        snapshot_html "$snapshot" "$json" "$watch" "$links" "$note_text" \
            "$form_nonce" "$flash_text"
        if [ "$first" = 1 ]; then
            note "snapshot=$snapshot"
            [ -z "$watch" ] || note "watch_seconds=$watch"
            first=0
        fi
        [ -n "$watch" ] || return 0
        sleep "$watch"
    done
}

