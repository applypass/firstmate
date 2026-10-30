#!/usr/bin/env bash
# Fork-only: fm-ask.sh - a read-only side session on any firstmate home (applypass fork).
#
# usage: fm-ask.sh [--model <m>] [--effort <e>] [-p|--print <question>] <home|mate-id|main>
#
# Opens a Claude session that answers questions about a home from that home's own
# records (data/, state/ status files, reports, backlog) and changes nothing. Use
# it while the home's own session is busy mid-turn: it never waits for that session.
#   <home>     an absolute path to a firstmate home (main or a second mate's);
#   <mate-id>  a second mate registered in the current home's data/secondmates.md;
#   main       the current home (FM_HOME, else this checkout).
# A remote second mate has no local home to read and is refused.
# With -p the session answers <question> once and exits; otherwise it is interactive.
#
# WHAT IT NEVER DOES
#   - It never takes the home's session lock and never runs bin/fm-session-start.sh,
#     so it cannot displace or confuse the home's own session or watcher.
#   - It never loads the home's project settings or CLAUDE.md (it starts in an empty
#     scratch directory with --setting-sources user), so none of the home's session
#     hooks, supervision cycle, or "you are the first mate" instructions run in it.
#   - It refuses every mutation. The session has only Read, Grep, Glob, and Bash
#     (--tools), runs in dontAsk mode, and every tool call passes
#     bin/fm-ask-pretool-check.sh, which refuses fm-send, fm-spawn, fm-pr-merge,
#     fm-wake-drain (including --ack-through), fm-captain-hold, fm-decide,
#     fm-tasks-axi writes, fm-teardown, fm-control, any file write, and any read
#     outside the home. The marker the hook honors is FM_ASK_READONLY=1 in the
#     session environment; FM_ASK_HOME names the home.
#   - Its system prompt says it is read-only and to hand every order to the real
#     firstmate or mate.
# THE ONE EXCEPTION. In a session on a second mate's home, an order is queued, not
# refused: bin/fm-ask-order.sh sends it to that mate's steering inbox through the
# normal bin/fm-send.sh path (run against the mate's parent home) and prints what
# the mate is doing, so the session answers "queued, the mate is mid-turn on ...".
# Its target is fixed from the home's own markers (FM_ASK_ORDER_HOME and
# FM_ASK_ORDER_TARGET). A main-home session has no such target and refuses orders.
#
# Environment: FM_ASK_CLAUDE_BIN overrides the claude executable (tests);
# FM_ASK_SCRATCH overrides the empty scratch directory the session starts in
# (default ${XDG_STATE_HOME:-~/.local/state}/firstmate-ask; Claude asks to trust it
# once). docs/captain-direct-mate-access.md owns the operator view.
set -u

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || exit 1
FM_ROOT=${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd -P)} || exit 1
CALLER_HOME=${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}

usage() { sed -n '2,/^set -u/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }
die() { echo "fm-ask: $*" >&2; exit 1; }

MODEL=
EFFORT=
QUESTION=
PRINT=0
TARGET=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --model) [ "$#" -gt 1 ] || die "--model needs a value"; MODEL=$2; shift 2 ;;
    --effort) [ "$#" -gt 1 ] || die "--effort needs a value"; EFFORT=$2; shift 2 ;;
    -p|--print) [ "$#" -gt 1 ] || die "$1 needs a question"; PRINT=1; QUESTION=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown option: $1" ;;
    *) [ -z "$TARGET" ] || die "one home only (got '$TARGET' and '$1')"; TARGET=$1; shift ;;
  esac
done
[ -n "$TARGET" ] || { usage >&2; exit 2; }

HOME_DIR=
case "$TARGET" in
  main) HOME_DIR=$CALLER_HOME ;;
  /*) HOME_DIR=$TARGET ;;
  *)
    REG="$CALLER_HOME/data/secondmates.md"
    [ -f "$REG" ] || die "no second mate registry at $REG; pass an absolute home path"
    # shellcheck source=bin/fm-secondmate-registry-lib.sh
    . "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
    line=$(grep -E "^- ${TARGET//./\\.} - " "$REG" | head -n 1)
    [ -n "$line" ] || die "no second mate '$TARGET' in $REG"
    secondmate_registry_parse_line "$line" || die "cannot parse the registry line for '$TARGET'"
    [ "$SECONDMATE_REGISTRY_REMOTE" = 0 ] || die "'$TARGET' is a remote second mate; its home is not readable here"
    HOME_DIR=$SECONDMATE_REGISTRY_HOME
    ;;
esac
HOME_DIR=$(CDPATH='' cd -- "$HOME_DIR" 2>/dev/null && pwd -P) || die "home '$TARGET' is not a directory"
[ -d "$HOME_DIR/state" ] && [ -d "$HOME_DIR/data" ] || die "$HOME_DIR does not look like a firstmate home (no state/ and data/)"

ORDER_HOME=
ORDER_TARGET=
if [ -f "$HOME_DIR/.fm-secondmate-home" ]; then
  ORDER_TARGET=$(tr -d '[:space:]' < "$HOME_DIR/.fm-secondmate-home")
  WHO="second mate $ORDER_TARGET"
  # A local mate's parent home is where fm-send resolves the mate; a remote or
  # unreadable binding leaves orders refused.
  # shellcheck source=bin/fm-secondmate-parent-lib.sh
  . "$SCRIPT_DIR/fm-secondmate-parent-lib.sh"
  if fm_secondmate_parent_record_parse "$HOME_DIR/.fm-secondmate-parent" && [ "$FM_SECONDMATE_PARENT_ROUTE" = local ]; then
    ORDER_HOME=$FM_SECONDMATE_PARENT_HOME
  else
    ORDER_TARGET=
  fi
else
  WHO="main firstmate"
fi

CLAUDE_BIN=${FM_ASK_CLAUDE_BIN:-claude}
command -v "$CLAUDE_BIN" >/dev/null 2>&1 || die "$CLAUDE_BIN not found on PATH"
command -v jq >/dev/null 2>&1 || die "jq is required"
BIN=$(printf %q "$SCRIPT_DIR")
SCRATCH=${FM_ASK_SCRATCH:-${XDG_STATE_HOME:-$HOME/.local/state}/firstmate-ask}
mkdir -p "$SCRATCH" || die "cannot create $SCRATCH"

PROMPT="You are a READ-ONLY side session on the $WHO's home at $HOME_DIR. The real session of that home may be mid-turn right now; you are not it. You hold no session lock, you run no supervision, and you change nothing.

Answer the captain's questions only from that home's own records: data/ (backlog, decisions, reports, charter), state/ (status files, task meta, ledgers), and config/. Read them with Read, Grep, Glob, and read-only Bash (cat, ls, grep, jq, $BIN/fm-crew-state.sh, $BIN/fm-fleet-view.sh, $BIN/fm-tasks-axi.sh list or show). Name the file you got each fact from. If the records do not say, say so; do not guess. A status line is an event, not current state: check $BIN/fm-crew-state.sh before calling anything current. Answer fast: lead with the answer, plain words, short.

You cannot send, spawn, merge, drain wakes, hold, decide, write the backlog, tear down, or write any file; every such call is refused by a hook. Do not look for a way around it."
if [ -n "$ORDER_TARGET" ]; then
  PROMPT="$PROMPT

The one exception: when the captain gives an order or asks for a change, queue it to the second mate that owns this home with $BIN/fm-ask-order.sh '<the order in the captain's words>'. It writes to that mate's steering inbox through the normal send path and prints what the mate is doing now. Reply 'queued' and say what the mate is mid-turn on (from the mate-state and latest-status lines it printed); never claim the order was done. Any other change is not yours: tell him to hand it to the real firstmate."
else
  PROMPT="$PROMPT

When the captain gives an order or asks for a change, do not try it: tell him to hand it to the real firstmate and say what to hand over."
fi
PROMPT="$PROMPT Address him as captain."

ARGS=(
  --setting-sources user
  --settings "$(jq -cn --arg hook "$(printf %q "$SCRIPT_DIR/fm-ask-pretool-check.sh")" '{hooks: {PreToolUse: [{matcher: ".*", hooks: [{type: "command", command: $hook}]}]}}')"
  --tools "Read,Grep,Glob,Bash"
  --allowedTools "Read Grep Glob Bash"
  --permission-mode dontAsk
  --strict-mcp-config
  --disable-slash-commands
  --add-dir "$HOME_DIR"
  --append-system-prompt "$PROMPT"
)
[ -z "$MODEL" ] || ARGS+=(--model "$MODEL")
[ -z "$EFFORT" ] || ARGS+=(--effort "$EFFORT")
[ "$PRINT" = 0 ] || ARGS+=(-p "$QUESTION")

cd "$SCRATCH" || die "cannot enter $SCRATCH"
export FM_HOME="$HOME_DIR" FM_ASK_READONLY=1 FM_ASK_HOME="$HOME_DIR" GIT_OPTIONAL_LOCKS=0
unset FM_ASK_ORDER_HOME FM_ASK_ORDER_TARGET
if [ -n "$ORDER_TARGET" ]; then export FM_ASK_ORDER_HOME="$ORDER_HOME" FM_ASK_ORDER_TARGET="$ORDER_TARGET"; fi
exec "$CLAUDE_BIN" "${ARGS[@]}"
