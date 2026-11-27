# ---- escaping and JSON ----
# The escapers and emitters: JSON strings and numbers, HTML text, page
# classes, action forms and the JSON PR array.
json_str() {
    # json_str STRING -> a quoted JSON string. Session names are already
    # restricted by valid_name, so only values need escaping: a pane carries
    # tabs, newlines and CR from tmux, and prose may carry quotes and
    # backslashes. This is not a general JSON writer, only a string escaper for
    # values this tool produces. Byte-wise in the C locale so a multibyte glyph
    # is re-emitted unchanged instead of being split.
    local s=${1-} out='' c i
    local LC_ALL=C
    for ((i = 0; i < ${#s}; i++)); do
        c=${s:i:1}
        case "$c" in
            '\') out+='\\' ;;
            '"') out+='\"' ;;
            $'\n') out+='\n' ;;
            $'\r') out+='\r' ;;
            $'\t') out+='\t' ;;
            $'\b') out+='\b' ;;
            $'\f') out+='\f' ;;
            [[:cntrl:]])
                printf -v c '\\u%04x' "'$c"
                out+=$c
                ;;
            *) out+=$c ;;
        esac
    done
    printf '"%s"' "$out"
}

json_nullable_str() {
    # json_nullable_str VALUE -> "value", or null for empty and for the `-`
    # placeholder the human views print for "not applicable"
    if [ -n "${1:-}" ] && [ "$1" != '-' ]; then
        json_str "$1"
    else
        printf 'null'
    fi
}

json_nullable_num() {
    # json_nullable_num VALUE -> a bare number, or null when it is not one
    if is_num "${1:-}"; then
        printf '%s' "$1"
    else
        printf 'null'
    fi
}

html_escape() {
    # html_escape STRING -> text that cannot leave its element. Branch names,
    # PR URLs, commit subjects and result text are arbitrary, so every value
    # in the snapshot goes through here; session names are constrained but
    # are escaped too so no value is trusted.
    local s=${1-}
    # The ampersands are backslash-quoted: bash 5.2 replaces an unquoted `&`
    # in a substitution's replacement with the matched text.
    s=${s//&/\&amp;}
    s=${s//</\&lt;}
    s=${s//>/\&gt;}
    s=${s//\"/\&quot;}
    s=${s//\'/\&#39;}
    printf '%s' "$s"
}

json_unescape() {
    # json_unescape STRING -> the decoded content of a JSON string, for
    # display. Only the escapes json_str emits are decoded; a \uXXXX sequence
    # is left as written, which is safe because html_escape runs afterwards.
    local s=${1-} out='' c i
    for ((i = 0; i < ${#s}; i++)); do
        c=${s:i:1}
        if [ "$c" = '\' ] && [ $((i + 1)) -lt ${#s} ]; then
            i=$((i + 1))
            c=${s:i:1}
            case "$c" in
                n|r|t) c=' ' ;;
                b|f) c='' ;;
                '"'|'\'|'/') ;;
                *) c='\'$c ;;
            esac
        fi
        out+=$c
    done
    printf '%s' "$out"
}

json_scalar() {
    # json_scalar VALUE -> a decoded value, empty for null
    local v=${1-}
    [ "$v" != null ] || return 0
    case "$v" in
        \"*\")
            v=${v:1:${#v}-2}
            json_unescape "$v"
            return 0
            ;;
    esac
    printf '%s' "$v"
}

state_class() {
    # state_class STATE -> a CSS class, so only known words reach the markup
    case "${1:-}" in
        done) printf 'done' ;;
        working) printf 'working' ;;
        idle|stopped) printf 'idle' ;;
        refused) printf 'refused' ;;
        blocked|failed) printf 'failed' ;;
        *) printf 'other' ;;
    esac
}

action_form() {
    # action_form NONCE ACTION LABEL -> one server-rendered POST form.
    # The nonce is the server's CSRF secret: a cookie-authenticated POST has
    # no other way to prove the form came from this page. No script, so a
    # stray click is the only risk left, and the stop routes answer with a
    # confirmation page before they act.
    local nonce=$1 action=$2 label=$3
    printf '<form method="post" action="%s">' "$(html_escape "$action")"
    printf '<input type="hidden" name="nonce" value="%s">' \
        "$(html_escape "$nonce")"
    printf '<button type="submit">%s</button></form>' "$(html_escape "$label")"
}

stylesheet_file() {
    # stylesheet_file -> gui/page.css next to the tool. It is the one
    # stylesheet: this renderer inlines it into the snapshot, and
    # gui/server.py inlines the same file into the stop confirmation and the
    # action-result page. Resolved from $0, not ROOT, because the asset ships
    # with the tool rather than with the repository it inspects.
    local dir
    case "$0" in
        */*) dir=$(cd -- "$(dirname -- "$0")" && pwd) ;;
        *) dir=$(cd -- "$(dirname -- "$(command -v -- "$0" 2>/dev/null || printf '%s' "$0")")" && pwd) ;;
    esac
    printf '%s/gui/page.css' "$dir"
}

pr_json_array() {
    # pr_json_array "pr=#N URL TITLE" lines -> [{number,url,title}, ...]
    # The human `pr=` lines already carry all three, so nesting them loses
    # nothing. Empty input is [] rather than null: null means gh was not asked.
    local line number url title first=1
    printf '['
    while IFS=$'\t' read -r number url title; do
        case "$number" in
            ''|*[!0-9]*) continue ;;
        esac
        [ "$first" = 1 ] || printf ', '
        first=0
        printf '{"number": %s, "url": %s, "title": %s}' \
            "$number" "$(json_str "$url")" "$(json_str "${title:-}")"
    done <<<"$(printf '%s\n' "${1:-}" |
        sed -E 's/^pr=#([0-9]+) ([^ ]+)( (.*))?$/\1\t\2\t\4/')"
    printf ']'
}

