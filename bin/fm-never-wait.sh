#!/usr/bin/env bash
# Fork-only: fm-never-wait.sh - enforce "never wait unless the captain asked or a resource ran out" (applypass fork).
#
# usage:
#   fm-never-wait.sh brief-check <brief-file> [--now EPOCH]
#   fm-never-wait.sh sweep [--now EPOCH] [--threshold SECONDS]
#   fm-never-wait.sh playbook <text>
#
# brief-check  refuses (exit 1) a worker brief that sets up a wait the worker
#          can end itself. Two checks, each naming the line and the fix:
#          1. a line that tells the worker to report blocked while asking for,
#             waiting for, or needing something on the self-obtainable list:
#               - a Vercel share link (mint it with the Vercel MCP and save it),
#               - a Clerk test session JWT (mint one for a donotdelete user),
#               - test database access (psql-17 through ~/.pgpass),
#               - SigNoz logs (the SigNoz MCP or the signoz-rest-api route);
#          2. handed-over access that expires within 2 hours: a JWT whose exp
#             claim is under 2 h away, "expires in N minutes/hours" under 2 h,
#             or an expires/exp timestamp under 2 h away.
# sweep    reads every state/<id>.status and handles the task's open block (a
#          trailing run of `blocked` lines). Prints one line of findings, or
#          nothing; the watcher turns a finding into a wake (bin/fm-watch.sh).
#          3. A block must start its text with one reason: captain-credential,
#             captain-decision, resource-exhausted, or "external-wait
#             until=<UTC time>" with the end time. Any other block is rejected
#             once and routed to the supervisor as a self-fix, with the
#             playbook step for the blocker it names (4).
#          5. A block older than --threshold (default 900 s, 15 min) with no
#             action since (no later status line, steer, or ledger event)
#             alarms the supervisor, which tells the captain; it repeats each
#             threshold until someone acts. Every block is also a
#             blocked-start / blocked-end pair in the task ledger, so the time
#             counts as blocked time (bin/fm-task-ledger.sh summary).
#          FM_NEVER_WAIT=off turns the whole command off; tests/lib.sh sets it.
# playbook prints the self-fix for a blocker's text (check 4): the supervisor
#          runs it the same turn and steers the worker, instead of waiting.
#
# Callers: bin/fm-spawn.sh (brief-check, every fresh ship or scout launch) and
# bin/fm-watch.sh (sweep, every poll; it throttles itself to once a minute).
# bin/fm-brief.sh teaches workers the reasons. docs/configuration.md "Never wait"
# owns the operator view.
set -u

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || exit 1
ROOT=$(cd "$SCRIPT_DIR/.." && pwd -P)
FM_HOME=${FM_HOME:-$ROOT}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
LEDGER="$SCRIPT_DIR/fm-task-ledger.sh"
SELF_FIX_FALLBACK="no known playbook: diagnose it, fix it, and steer the worker with fm-send; only a captain credential, a captain decision, an exhausted resource, or a timed external wait may stay blocked"

usage() { sed -n '2,/^set -u/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

# route_for <text>: prints "<name>|<self-fix step>" for the self-obtainable
# blocker the text names, and returns 1 when it names none. One owner of the
# list, shared by the brief check (1) and the playbook (4).
route_for() {
  local t
  t=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  if printf '%s' "$t" | grep -Eq 'share[ -]?link|vercel.*(link|bypass|protect|preview|expired)|(expired|stale).*(preview|test[ -]site|link)'; then
    echo "vercel-share-link|mint a fresh share link with the Vercel MCP (get_access_to_vercel_url), save it under the task's data directory, then steer the worker with fm-send to use it and continue"
  elif printf '%s' "$t" | grep -Eq 'clerk|session (jwt|token)|jwt'; then
    echo "clerk-session-jwt|mint a Clerk session JWT for a donotdelete test user, save it under the task's data directory, then steer the worker with fm-send to use it and continue"
  elif printf '%s' "$t" | grep -Eq 'test (db|database)|database access|db access|psql|pgpass'; then
    echo "test-db-access|test database access is psql-17 through ~/.pgpass (the test dev-agent has full access; prod is read-only through dev-agent-ro); give the worker the exact command with fm-send and continue"
  elif printf '%s' "$t" | grep -Eq 'signoz'; then
    echo "signoz-logs|read SigNoz through its MCP or the signoz-rest-api route, paste the evidence into the task's data directory, then steer the worker with fm-send and continue"
  else
    return 1
  fi
}

now_epoch() { date +%s; }

# iso_epoch <YYYY-MM-DDTHH:MM[:SS]Z>: epoch seconds, empty when unparsable.
iso_epoch() {
  local v=$1 out
  case "$v" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]Z) v="${v%Z}:00Z" ;;
  esac
  case "$v" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;;
    *) return 1 ;;
  esac
  out=$(date -u -d "$v" +%s 2>/dev/null) || out=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$v" +%s 2>/dev/null) || return 1
  printf '%s' "$out"
}

touch_epoch() {  # <file> <epoch>
  touch -d "@$2" "$1" 2>/dev/null || touch -t "$(date -r "$2" +%Y%m%d%H%M.%S 2>/dev/null)" "$1" 2>/dev/null
}

# --- brief-check --------------------------------------------------------------

jwt_exp() {  # <token>: the exp claim, empty when absent
  local payload pad
  payload=$(printf '%s' "$1" | cut -d. -f2 | tr '_-' '/+')
  pad=$(( (4 - ${#payload} % 4) % 4 ))
  while [ "$pad" -gt 0 ]; do payload="$payload="; pad=$((pad - 1)); done
  printf '%s' "$payload" | base64 -d 2>/dev/null | jq -r '.exp // empty' 2>/dev/null
}

brief_check() {  # <file> <now>
  local file=$1 now=$2 line n=0 refused=0 route name step horizon=$(( $2 + 7200 )) tok exp num unit secs when
  [ -f "$file" ] || { echo "fm-never-wait: no brief at $file" >&2; return 2; }
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    # 1. "report blocked asking for X" where X is on the self-obtainable list.
    if printf '%s' "$line" | grep -Eqi 'blocked' && printf '%s' "$line" | grep -Eqi '(ask|asking|wait|waiting|request|requesting|need|needs|needing|until)'; then
      if route=$(route_for "$line"); then
        name=${route%%|*}
        step=${route#*|}
        printf 'never wait: brief line %s tells the worker to report blocked on something it can get itself (%s): %s\n  fix: rewrite the line to say how the worker gets it - %s\n' "$n" "$name" "$line" "$step" >&2
        refused=1
      fi
    fi
    # 2a. a handed-over JWT that expires within 2 hours.
    for tok in $(printf '%s' "$line" | grep -Eo 'eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]*'); do
      exp=$(jwt_exp "$tok")
      case "$exp" in '' | *[!0-9]*) continue ;; esac
      if [ "$exp" -lt "$horizon" ]; then
        printf 'never wait: brief line %s hands over a token that expires %s (within 2 hours of launch); the worker would stall when it lapses\n  fix: mint a fresh one with at least 2 hours left, or tell the worker how to mint its own\n' "$n" "$([ "$exp" -le "$now" ] && echo 'already' || echo "in $(( (exp - now) / 60 )) minutes")" >&2
        refused=1
      fi
    done
    # 2b. "expires in N minutes/hours".
    if printf '%s' "$line" | grep -Eqi 'expires? (in|within) [0-9]+ ?(m|min|mins|minutes?|h|hrs?|hours?)\b'; then
      num=$(printf '%s' "$line" | grep -Eoi 'expires? (in|within) [0-9]+' | grep -Eo '[0-9]+$' | head -1)
      unit=$(printf '%s' "$line" | grep -Eoi 'expires? (in|within) [0-9]+ ?[a-z]+' | head -1 | sed -E 's/.*[0-9] ?//' | tr '[:upper:]' '[:lower:]')
      case "$unit" in h* ) secs=$((num * 3600)) ;; *) secs=$((num * 60)) ;; esac
      if [ "$secs" -lt 7200 ]; then
        printf 'never wait: brief line %s hands over access that expires in %s %s (under 2 hours)\n  fix: mint access with at least 2 hours left, or tell the worker how to mint its own\n' "$n" "$num" "$unit" >&2
        refused=1
      fi
    fi
    # 2c. "expires at <ISO time>" or exp=<epoch>.
    when=$(printf '%s' "$line" | grep -Eoi 'expires?(_at)?([ =:]+at)?[ =:]+[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z' | head -1 | grep -Eo '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z')
    if [ -n "$when" ] && exp=$(iso_epoch "$when") && [ "$exp" -lt "$horizon" ]; then
      printf 'never wait: brief line %s hands over access that expires at %s (within 2 hours of launch)\n  fix: mint access with at least 2 hours left, or tell the worker how to mint its own\n' "$n" "$when" >&2
      refused=1
    fi
    when=$(printf '%s' "$line" | grep -Eoi '(^|[^a-z])exp(ires)?(_at)?=[0-9]{9,11}' | head -1 | grep -Eo '[0-9]+$')
    if [ -n "$when" ] && [ "$when" -lt "$horizon" ]; then
      printf 'never wait: brief line %s hands over access that expires at epoch %s (within 2 hours of launch)\n  fix: mint access with at least 2 hours left, or tell the worker how to mint its own\n' "$n" "$when" >&2
      refused=1
    fi
  done < "$file"
  [ "$refused" -eq 0 ]
}

# --- sweep -------------------------------------------------------------------

# status_field <line> at: the [at=N] stamp, empty when absent.
line_at() { printf '%s' "$1" | sed -n 's/^[^[]*\[at=\([0-9]*\)\].*/\1/p' | head -1; }
# line_text <line>: the text after the first ": ".
line_text() { printf '%s' "$1" | sed -n 's/^[^:]*: *//p'; }
line_verb() { printf '%s' "$1" | sed -n 's/^[[:space:]]*\([a-z-]*\).*/\1/p'; }

legal_reason() {  # <text>: 0 when the block carries one of the four reasons
  local text until
  text=$(printf '%s' "$1" | sed 's/^[[:space:]]*//' | tr '[:upper:]' '[:lower:]')
  case "$text" in
    captain-credential* | captain-decision* | resource-exhausted*) return 0 ;;
    external-wait\ until=*)
      until=$(printf '%s' "$text" | sed -n 's/^external-wait until=\([0-9t:-]*z\).*/\1/p' | tr 'tz' 'TZ')
      [ -n "$until" ] && iso_epoch "$until" >/dev/null
      return $? ;;
  esac
  return 1
}

sweep() {  # <now> <threshold>
  local now=$1 threshold=$2 f id findings='' lines last_lines run_start first_line first_at text age
  local dir="$STATE/never-wait" ref action marker last_alarm route step msg verb l ledger
  [ -d "$STATE" ] || return 0
  mkdir -p "$dir" 2>/dev/null || return 0
  for f in "$STATE"/*.status; do
    [ -f "$f" ] || continue
    id=$(basename "$f" .status)
    case "$id" in *[!A-Za-z0-9._-]*) continue ;; esac
    lines=$(grep -c '' "$f" 2>/dev/null || echo 0)
    [ "$lines" -gt 0 ] || continue
    # The trailing run of blocked lines (blank lines skipped) is the open block.
    last_lines=$(grep -n . "$f" | tail -50)
    run_start=''
    while IFS= read -r l; do
      verb=$(line_verb "${l#*:}")
      if [ "$verb" = blocked ]; then
        [ -n "$run_start" ] || run_start=$l
      else
        run_start=''
      fi
    done <<EOF
$last_lines
EOF
    if [ -z "$run_start" ]; then
      # No open block: close a ledger block that is still open.
      close_ledger_block "$id" "$f" "$now"
      continue
    fi
    first_line=${run_start#*:}
    first_at=$(line_at "$first_line")
    [ -n "$first_at" ] || first_at=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo "$now")
    text=$(line_text "$first_line")
    age=$((now - first_at))
    FM_HOME=$FM_HOME "$LEDGER" record "$id" blocked-start --at "$first_at" --dedupe --note "${text:0:200}" >/dev/null 2>&1 || true
    # 3 and 4: an illegal reason is rejected once and routed as a self-fix.
    if ! legal_reason "$text"; then
      marker="$dir/$id.rejected-$first_at"
      if [ ! -e "$marker" ]; then
        : > "$marker"
        if route=$(route_for "$text"); then step=${route#*|}; else step=$SELF_FIX_FALLBACK; fi
        findings="${findings}${findings:+ | }SELF-FIX $id: its blocked line carries no legal reason (captain-credential, captain-decision, resource-exhausted, or external-wait until=<UTC time>), so it is not a wait: $step"
      fi
    fi
    # 5: a block older than the threshold with no action alarms.
    [ "$age" -ge "$threshold" ] || continue
    ref="$dir/.ref-$id"
    touch_epoch "$ref" "$first_at" || continue
    action=''
    # A steer message or a ledger event (turn charges excluded) after the block is action; a later
    # status line cannot exist, since it would have ended the trailing run of blocked lines.
    if [ -d "$STATE/$id.inbox" ] && [ -n "$(find "$STATE/$id.inbox" -type f -newer "$ref" 2>/dev/null | head -1)" ]; then action=1; fi
    if [ -z "$action" ] && ledger=$(FM_HOME=$FM_HOME "$LEDGER" path "$id" 2>/dev/null) && [ -s "$ledger" ]; then
      [ "$(jq -rs --argjson at "$first_at" '[.[] | select(.at > $at and .event != "turn" and .event != "blocked-start")] | length' "$ledger")" -eq 0 ] || action=1
    fi
    rm -f "$ref"
    [ -z "$action" ] || continue
    marker="$dir/$id.alarm"
    last_alarm=$(cat "$marker" 2>/dev/null || echo 0)
    case "$last_alarm" in '' | *[!0-9]*) last_alarm=0 ;; esac
    [ $((now - last_alarm)) -ge "$threshold" ] || continue
    printf '%s\n' "$now" > "$marker"
    msg="ALARM $id: blocked $((age / 60)) minutes with no action ($(printf '%s' "$text" | cut -c1-120)); act on it now and tell the captain"
    findings="${findings}${findings:+ | }$msg"
  done
  [ -z "$findings" ] || printf '%s\n' "$findings"
  return 0
}

close_ledger_block() {  # <id> <status-file> <now>
  local id=$1 f=$2 now=$3 open_at end_at
  open_at=$(FM_HOME=$FM_HOME "$LEDGER" open-block "$id" 2>/dev/null) || return 0
  [ -n "$open_at" ] || return 0
  # The block ended at the first status line stamped after it; else now.
  end_at=$(grep -v '^[[:space:]]*$' "$f" | while IFS= read -r l; do
    a=$(line_at "$l")
    [ -n "$a" ] && [ "$a" -gt "$open_at" ] && { echo "$a"; break; }
  done)
  [ -n "$end_at" ] || end_at=$now
  FM_HOME=$FM_HOME "$LEDGER" record "$id" blocked-end --at "$end_at" >/dev/null 2>&1 || true
}

CMD=${1:-}
[ -n "$CMD" ] || { usage >&2; exit 2; }
shift
case "$CMD" in -h | --help) usage; exit 0 ;; esac
[ "${FM_NEVER_WAIT:-}" != off ] || exit 0
NOW=''
THRESHOLD=900
FILE=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --now) [ "$#" -gt 1 ] || { echo "error: --now needs a value" >&2; exit 2; }; NOW=$2; shift 2 ;;
    --threshold) [ "$#" -gt 1 ] || { echo "error: --threshold needs a value" >&2; exit 2; }; THRESHOLD=$2; shift 2 ;;
    *) if [ -z "$FILE" ]; then FILE=$1; shift; else echo "error: unknown argument: $1" >&2; exit 2; fi ;;
  esac
done
[ -n "$NOW" ] || NOW=$(now_epoch)
case "$NOW$THRESHOLD" in *[!0-9]*) echo "error: --now and --threshold must be whole seconds" >&2; exit 2 ;; esac
case "$CMD" in
  brief-check)
    [ -n "$FILE" ] || { usage >&2; exit 2; }
    brief_check "$FILE" "$NOW"
    ;;
  sweep)
    # Throttle: at most one sweep a minute per home, unless a test pins --now.
    if [ -z "${FM_NEVER_WAIT_UNTHROTTLED:-}" ] && [ -f "$STATE/never-wait/.last-sweep" ]; then
      last=$(cat "$STATE/never-wait/.last-sweep" 2>/dev/null || echo 0)
      case "$last" in '' | *[!0-9]*) last=0 ;; esac
      [ $((NOW - last)) -ge 60 ] || exit 0
    fi
    mkdir -p "$STATE/never-wait" 2>/dev/null && printf '%s\n' "$NOW" > "$STATE/never-wait/.last-sweep"
    sweep "$NOW" "$THRESHOLD"
    ;;
  playbook)
    [ -n "$FILE" ] || { usage >&2; exit 2; }
    if route=$(route_for "$FILE"); then printf '%s: %s\n' "${route%%|*}" "${route#*|}"; else printf '%s\n' "$SELF_FIX_FALLBACK"; fi
    ;;
  *) usage >&2; exit 2 ;;
esac
