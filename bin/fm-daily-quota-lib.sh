# shellcheck shell=bash
# Fork-only: daily Claude quota stop (applypass fork).
#
# Sourced by bin/fm-daily-quota-stop.sh. Decides whether this fleet may start
# NEW work today from one number: the share of the weekly Claude quota spent
# since the start of the current local day. Running work is never affected.
#
# Reads quota through quota-axi only (never another harness CLI), as the
# quota-axi --provider claude --json snapshot. The weekly window's
# percentRemaining gives "used now"; the day-start baseline is persisted once
# per local day in the fleet home so every home shares one budget.
#
# Fleet home: the home reached by following each home's durable
# .fm-secondmate-parent binding (local route) up to the main home, so a
# secondmate restart that loses its launch environment still spends the main
# home's budget. A home with no local binding is its own fleet home. Files there:
#   state/daily-quota-day-start      key=value baseline (see fm_dq_baseline_write)
#   state/daily-quota-reported/      one marker per home, day, and level
# Thresholds are the fixed constants below: 20% refuses, 25% holds.
#
# Test hooks: FM_DAILY_QUOTA_NOW (epoch seconds) replaces the clock.

# shellcheck source=bin/fm-secondmate-parent-lib.sh
. "${BASH_SOURCE[0]%/*}/fm-secondmate-parent-lib.sh"

FM_DQ_REFUSE_PCT=20
FM_DQ_HOLD_PCT=25

# Result globals set by fm_dq_evaluate.
FM_DQ_VERDICT=      # ok | refuse | hold | unreadable | error
FM_DQ_USED_NOW=
FM_DQ_USED_TODAY=
FM_DQ_REASON=       # why quota could not be read, or the record could not be written
FM_DQ_CLEARS=       # human-readable local time the hold clears (hold only)

fm_dq_now() {
  case "${FM_DAILY_QUOTA_NOW:-}" in
    ''|*[!0-9]*) date +%s ;;
    *) printf '%s\n' "$FM_DAILY_QUOTA_NOW" ;;
  esac
}

# fm_dq_date <strftime-format> <epoch>: BSD date first, GNU date second.
fm_dq_date() {
  date -r "$2" "+$1" 2>/dev/null || date -d "@$2" "+$1" 2>/dev/null
}

# The fleet home that owns the shared day-start record: follow local parent
# bindings up (bounded) to the main home.
fm_dq_fleet_home() {  # <this-home>
  local home=$1 depth=0
  while [ "$depth" -lt 8 ]; do
    fm_secondmate_parent_record_parse "$home/.fm-secondmate-parent" || break
    [ "$FM_SECONDMATE_PARENT_ROUTE" = local ] && [ -n "$FM_SECONDMATE_PARENT_HOME" ] || break
    home=$FM_SECONDMATE_PARENT_HOME
    depth=$((depth + 1))
  done
  printf '%s\n' "$home"
}

# Read the weekly Claude window. On success sets FM_DQ_USED_NOW (integer percent
# used) and FM_DQ_LAST_RESET (epoch of the last weekly reset, or empty); on
# failure sets FM_DQ_REASON and returns 1. Never guesses.
FM_DQ_LAST_RESET=
fm_dq_read_quota() {
  local out rc=0 parsed
  FM_DQ_USED_NOW=
  FM_DQ_LAST_RESET=
  FM_DQ_REASON=
  if ! command -v quota-axi >/dev/null 2>&1; then
    FM_DQ_REASON="quota-axi is not installed or not on PATH"
    return 1
  fi
  command -v jq >/dev/null 2>&1 || { FM_DQ_REASON="jq is not installed"; return 1; }
  out=$(quota-axi --provider claude --json 2>&1 </dev/null) || rc=$?
  if [ "$rc" -ne 0 ] && ! printf '%s' "$out" | jq -e . >/dev/null 2>&1; then
    FM_DQ_REASON="quota-axi exited $rc: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)"
    return 1
  fi
  parsed=$(printf '%s' "$out" | jq -r '
    def lastreset: (.resetsAt // "" | sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z")
      | try fromdateiso8601 catch null);
    ([.providers[]? | select(.provider == "claude")]) as $rows
    | (if (.schemaVersion // 5) == 6
         then (([$rows[] | select(.accountKey == "default")] | first) // null)
         else ($rows | first) // null end) as $row
    | if $row == null then "ERR\tno Claude row in the quota-axi snapshot (the Claude account is not set up or not readable)"
      elif ($row.state.stale // false) == true then "ERR\tthe Claude quota reading is stale"
      else
        ([$row.windows[]? | select(.kind == "weekly")] | first) as $w
        | if $w == null then
            "ERR\tno weekly Claude window in the snapshot" +
            (if ($row.state.status // "") != "" then " (state: " + $row.state.status + ")" else "" end)
          elif ($w.percentRemaining | type) != "number" then "ERR\tthe weekly Claude window has no percentRemaining"
          else "OK\t\(100 - $w.percentRemaining)\t\($w | lastreset // "")"
          end
      end' 2>/dev/null) || { FM_DQ_REASON="quota-axi output is not valid JSON"; return 1; }
  case "$parsed" in
    OK*)
      local rest=${parsed#OK$'\t'}
      FM_DQ_USED_NOW=${rest%%$'\t'*}
      rest=${rest#*$'\t'}
      # resetsAt is the NEXT reset; the last one is a week earlier.
      if [ -n "$rest" ]; then FM_DQ_LAST_RESET=$((rest - 604800)); fi
      case "$FM_DQ_USED_NOW" in ''|*[!0-9]*) FM_DQ_REASON="quota-axi returned a non-numeric weekly percentage"; return 1 ;; esac
      return 0
      ;;
    ERR*) FM_DQ_REASON=${parsed#ERR$'\t'}; return 1 ;;
    *) FM_DQ_REASON="quota-axi output could not be interpreted"; return 1 ;;
  esac
}

# Local midnight (epoch) of the day containing <epoch>.
fm_dq_midnight() {  # <epoch>
  local hms h m s
  hms=$(fm_dq_date '%H %M %S' "$1") || return 1
  read -r h m s <<< "$hms"
  # 10# keeps zero-padded values from reading as octal.
  printf '%s\n' $(( $1 - 10#$h * 3600 - 10#$m * 60 - 10#$s ))
}

fm_dq_baseline_file() { printf '%s/state/daily-quota-day-start\n' "$1"; }

# Baseline record: day=YYYY-MM-DD, used=<percent at the day's start>,
# held=0|1 (the hold line was crossed today and holds until the next day),
# last=<percent at the latest check>, last_at=<epoch of that check>. The latest
# check of one day is the next day's baseline, so a day's spend counts from
# local midnight rather than from the day's first check.
fm_dq_baseline_read() {  # <file> -> sets FM_DQ_B_DAY FM_DQ_B_USED FM_DQ_B_HELD FM_DQ_B_LAST FM_DQ_B_LAST_AT
  local line
  FM_DQ_B_DAY=; FM_DQ_B_USED=; FM_DQ_B_HELD=0; FM_DQ_B_LAST=; FM_DQ_B_LAST_AT=
  [ -f "$1" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      day=*) FM_DQ_B_DAY=${line#day=} ;;
      used=*) FM_DQ_B_USED=${line#used=} ;;
      held=*) FM_DQ_B_HELD=${line#held=} ;;
      last=*) FM_DQ_B_LAST=${line#last=} ;;
      last_at=*) FM_DQ_B_LAST_AT=${line#last_at=} ;;
    esac
  done < "$1"
  case "$FM_DQ_B_USED" in ''|*[!0-9]*) return 1 ;; esac
  case "$FM_DQ_B_LAST" in *[!0-9]*) FM_DQ_B_LAST= ;; esac
  case "$FM_DQ_B_LAST_AT" in *[!0-9]*) FM_DQ_B_LAST_AT= ;; esac
  [ -n "$FM_DQ_B_DAY" ]
}

fm_dq_baseline_write() {  # <file> <day> <used> <held> <last> <last_at>
  local tmp
  mkdir -p "$(dirname "$1")" || return 1
  tmp=$(mktemp "$1.XXXXXX") || return 1
  if printf 'day=%s\nused=%s\nheld=%s\nlast=%s\nlast_at=%s\n' "$2" "$3" "$4" "$5" "$6" > "$tmp" && mv "$tmp" "$1"; then return 0; fi
  rm -f "$tmp"
  return 1
}

# Decide for <this-home>. Sets FM_DQ_VERDICT and the companion globals; returns
# 0 for ok and 1 otherwise (so callers read the verdict for the reason).
fm_dq_evaluate() {  # <this-home>
  local fleet file now day midnight baseline held
  fleet=$(fm_dq_fleet_home "$1")
  file=$(fm_dq_baseline_file "$fleet")
  FM_DQ_VERDICT=; FM_DQ_USED_TODAY=; FM_DQ_CLEARS=
  now=$(fm_dq_now)
  if ! fm_dq_read_quota; then
    FM_DQ_VERDICT=unreadable
    return 1
  fi
  day=$(fm_dq_date %F "$now") || { FM_DQ_REASON="cannot read the local date"; FM_DQ_VERDICT=error; return 1; }
  midnight=$(fm_dq_midnight "$now") || { FM_DQ_REASON="cannot compute local midnight"; FM_DQ_VERDICT=error; return 1; }

  held=0
  baseline=$FM_DQ_USED_NOW
  if fm_dq_baseline_read "$file"; then
    if [ "$FM_DQ_B_DAY" = "$day" ]; then
      baseline=$FM_DQ_B_USED
      held=$FM_DQ_B_HELD
    elif [ -n "$FM_DQ_B_LAST" ] && [ -n "$FM_DQ_B_LAST_AT" ] &&
      [ "$FM_DQ_B_LAST_AT" -ge $((midnight - 86400)) ] && [ "$FM_DQ_B_LAST_AT" -lt "$midnight" ]; then
      # New local day: yesterday's latest reading is today's baseline. A reading
      # older than yesterday cannot say how much of the gap was today's.
      baseline=$FM_DQ_B_LAST
    fi
  fi
  # Usage that fell below the baseline, or a weekly reset today, means the week
  # restarted: everything used since the reset counts as today's. A drop counts
  # as a reset only when resetsAt is missing or puts the reset after the last
  # recorded reading; otherwise it is a reading wobble and used today clamps to 0.
  if [ "$FM_DQ_USED_NOW" -lt "$baseline" ] &&
    { [ -z "$FM_DQ_LAST_RESET" ] || [ "$FM_DQ_LAST_RESET" -gt "${FM_DQ_B_LAST_AT:-0}" ]; }; then
    baseline=0
  fi
  if [ -n "$FM_DQ_LAST_RESET" ] && [ "$FM_DQ_LAST_RESET" -ge "$midnight" ] && [ "$FM_DQ_LAST_RESET" -le "$now" ]; then
    baseline=0
  fi
  FM_DQ_USED_TODAY=$((FM_DQ_USED_NOW - baseline))
  [ "$FM_DQ_USED_TODAY" -ge 0 ] || FM_DQ_USED_TODAY=0

  if [ "$FM_DQ_USED_TODAY" -ge "$FM_DQ_HOLD_PCT" ]; then held=1; fi
  fm_dq_baseline_write "$file" "$day" "$baseline" "$held" "$FM_DQ_USED_NOW" "$now" ||
    { FM_DQ_REASON="cannot write $file"; FM_DQ_VERDICT=error; return 1; }

  if [ "$held" = 1 ]; then
    FM_DQ_VERDICT=hold
    FM_DQ_CLEARS=$(fm_dq_date '%F %H:%M %Z' $((midnight + 86400)))
    return 1
  fi
  if [ "$FM_DQ_USED_TODAY" -ge "$FM_DQ_REFUSE_PCT" ]; then
    FM_DQ_VERDICT=refuse
    return 1
  fi
  FM_DQ_VERDICT=ok
  return 0
}

# One-line plain-English message for the current verdict; empty for ok.
fm_dq_message() {  # <what: "worker launch" | "no-mistakes run">
  case "$FM_DQ_VERDICT" in
    refuse)
      printf 'daily quota stop: refusing a new %s. The fleet has used %s%% of the weekly Claude quota today, at or over the %s%% daily line. Running work finishes; new work waits for the captain or the next local day.\n' \
        "$1" "$FM_DQ_USED_TODAY" "$FM_DQ_REFUSE_PCT" ;;
    hold)
      printf 'daily quota stop: holding every new %s until %s. The fleet has used %s%% of the weekly Claude quota today, at or over the %s%% hold line. Running work finishes.\n' \
        "$1" "$FM_DQ_CLEARS" "$FM_DQ_USED_TODAY" "$FM_DQ_HOLD_PCT" ;;
    unreadable)
      printf 'daily quota stop: refusing a new %s because Claude quota could not be read (%s). The daily budget cannot be checked, so new work waits until quota-axi can read Claude quota (a Keychain approval may be pending); the captain decides whether to proceed.\n' \
        "$1" "$FM_DQ_REASON" ;;
    error)
      printf 'daily quota stop: refusing a new %s because the daily budget record could not be kept (%s). Claude quota was read, but without the record the day-start baseline is lost.\n' \
        "$1" "$FM_DQ_REASON" ;;
  esac
}
