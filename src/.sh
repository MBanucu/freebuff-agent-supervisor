# ---- the dispatch ----
# The --root peel, the help shortcut and the case over $cmd.
# --root is accepted before the subcommand so tests can point at a temp repo.
ROOT="${FREEBUFF_SUPERVISOR_ROOT:-}"
args=("$@")
while [ ${#args[@]} -gt 0 ]; do
    case "${args[0]}" in
        --root)
            [ ${#args[@]} -ge 2 ] || die "--root needs a directory"
            ROOT=${args[1]}
            args=("${args[@]:2}")
            ;;
        *) break ;;
    esac
done
set -- "${args[@]}"

# Help is about the tool, not about a checkout: answer it before the root
# lookup, so `--help` works from any directory (and the suites can run from
# anywhere, not only from inside the repo).
case "${1:-}" in
    -h|--help|help) usage; exit 0 ;;
esac

if [ -z "$ROOT" ]; then
    ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
fi
[ -n "$ROOT" ] || die "not inside a git repository"
[ -d "$ROOT" ] || die "root does not exist: $ROOT"

cmd=${1:-}
if [ $# -gt 0 ]; then
    shift
fi
case "$cmd" in
    start) start "$@" ;;
    status) status "$@" ;;
    list|ls) list_agents "$@" ;;
    sessions|ps) sessions "$@" ;;
    hours) hours "$@" ;;
    models) models "$@" ;;
    gui) gui "$@" ;;
    attach) attach "$@" ;;
    send) send "$@" ;;
    watch) watch "$@" ;;
    autostop) autostop "$@" ;;
    notify) notify "$@" ;;
    gc) gc "$@" ;;
    stop) stop "$@" ;;
    -h|--help|help) usage ;;
    '') usage; exit 2 ;;
    *) die "unknown command: $cmd (try --help)" ;;
esac
