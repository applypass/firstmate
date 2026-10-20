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
# Fleet home: ${FM_DAILY_QUOTA_HOME:-${FM_PUBLIC_FOLLOWUP_PRIMARY_HOME:-$FM_HOME}}.
# A secondmate home launches with FM_PUBLIC_FOLLOWUP_PRIMARY_HOME naming the
# main home, so its checks land on the main home's state. Files there:
#   state/daily-quota-day-start      key=value baseline (see fm_dq_baseline_write)
#   state/daily-quota-reported/      one marker per home, day, and level
#   state/daily-quota-allow-unreadable  one-shot captain grant (consumed on use)
#   config/daily-quota-stop          optional thresholds, see docs/configuration.md
#
# Test hooks: FM_DAILY_QUOTA_NOW (epoch seconds) replaces the clock.

FM_DQ_DEFAULT_REFUSE=20
FM_DQ_DEFAULT_HOLD=25

# Result globals set by fm_dq_evaluate.
FM_DQ_VERDICT=      # ok | refuse | hold | unreadable
FM_DQ_USED_NOW=
FM_DQ_USED_TODAY=
FM_DQ_REFUSE_PCT=
FM_DQ_HOLD_PCT=
FM_DQ_REASON=       # why the quota could not be read (unreadable only)
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

# The fleet home that owns the shared day-start record.
fm_dq_fleet_home() {  # <this-home>
  printf '%s\n' "${FM_DAILY_QUOTA_HOME:-${FM_PUBLIC_FOLLOWUP_PRIMARY_HOME:-$1}}"
}

# Thresholds: env, then the fleet home's config/daily-quota-stop, then 20/25.
# The file holds `refuse=<percent>` and `hold=<percent>` lines; # comments and
# blank lines are ignored. A malformed value falls back to the default.
fm_dq_load_thresholds() {  # <fleet-home>
  local file="$1/config/daily-quota-stop" line key val
  FM_DQ_REFUSE_PCT=$FM_DQ_DEFAULT_REFUSE
  FM_DQ_HOLD_PCT=$FM_DQ_DEFAULT_HOLD
  if [ -f "$file" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in ''|'#'*) continue ;; esac
      key=${line%%=*}
      val=${line#*=}
      key=$(printf '%s' "$key" | tr -d '[:space:]')
      val=$(printf '%s' "$val" | tr -d '[:space:]')
      case "$val" in ''|*[!0-9]*) continue ;; esac
      [ "$val" -le 100 ] || continue
      case "$key" in
        refuse) FM_DQ_REFUSE_PCT=$val ;;
        hold) FM_DQ_HOLD_PCT=$val ;;
      esac
    done < "$file"
  fi
  case "${FM_DAILY_QUOTA_REFUSE_PCT:-}" in ''|*[!0-9]*) ;; *) FM_DQ_REFUSE_PCT=$FM_DAILY_QUOTA_REFUSE_PCT ;; esac
  case "${FM_DAILY_QUOTA_HOLD_PCT:-}" in ''|*[!0-9]*) ;; *) FM_DQ_HOLD_PCT=$FM_DAILY_QUOTA_HOLD_PCT ;; esac
  # The hold line never sits below the refuse line.
  [ "$FM_DQ_HOLD_PCT" -ge "$FM_DQ_REFUSE_PCT" ] || FM_DQ_HOLD_PCT=$FM_DQ_REFUSE_PCT
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
# held=0|1 (the 25% line was crossed today and holds until the next day).
fm_dq_baseline_read() {  # <file> -> sets FM_DQ_B_DAY FM_DQ_B_USED FM_DQ_B_HELD
  local line
  FM_DQ_B_DAY=; FM_DQ_B_USED=; FM_DQ_B_HELD=0
  [ -f "$1" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      day=*) FM_DQ_B_DAY=${line#day=} ;;
      used=*) FM_DQ_B_USED=${line#used=} ;;
      held=*) FM_DQ_B_HELD=${line#held=} ;;
    esac
  done < "$1"
  case "$FM_DQ_B_USED" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$FM_DQ_B_DAY" ]
}

fm_dq_baseline_write() {  # <file> <day> <used> <held>
  local tmp
  mkdir -p "$(dirname "$1")" || return 1
  tmp=$(mktemp "$1.XXXXXX") || return 1
  if printf 'day=%s\nused=%s\nheld=%s\n' "$2" "$3" "$4" > "$tmp" && mv "$tmp" "$1"; then return 0; fi
  rm -f "$tmp"
  return 1
}

# Decide for <this-home>. Sets FM_DQ_VERDICT and the companion globals; returns
# 0 for ok and 1 otherwise (so callers read the verdict for the reason).
fm_dq_evaluate() {  # <this-home>
  local fleet file now day midnight baseline held
  fleet=$(fm_dq_fleet_home "$1")
  file=$(fm_dq_baseline_file "$fleet")
  fm_dq_load_thresholds "$fleet"
  FM_DQ_VERDICT=; FM_DQ_USED_TODAY=; FM_DQ_CLEARS=
  now=$(fm_dq_now)
  if ! fm_dq_read_quota; then
    FM_DQ_VERDICT=unreadable
    return 1
  fi
  day=$(fm_dq_date %F "$now") || { FM_DQ_REASON="cannot read the local date"; FM_DQ_VERDICT=unreadable; return 1; }
  midnight=$(fm_dq_midnight "$now") || { FM_DQ_REASON="cannot compute local midnight"; FM_DQ_VERDICT=unreadable; return 1; }

  held=0
  if fm_dq_baseline_read "$file" && [ "$FM_DQ_B_DAY" = "$day" ]; then
    baseline=$FM_DQ_B_USED
    held=$FM_DQ_B_HELD
    # A weekly reset today, or usage that fell since the baseline, means the
    # week restarted: everything used since the reset counts as today's.
    if [ "$FM_DQ_USED_NOW" -lt "$baseline" ]; then baseline=0; fi
  else
    baseline=$FM_DQ_USED_NOW
  fi
  if [ -n "$FM_DQ_LAST_RESET" ] && [ "$FM_DQ_LAST_RESET" -ge "$midnight" ] && [ "$FM_DQ_LAST_RESET" -le "$now" ]; then
    baseline=0
  fi
  FM_DQ_USED_TODAY=$((FM_DQ_USED_NOW - baseline))
  [ "$FM_DQ_USED_TODAY" -ge 0 ] || FM_DQ_USED_TODAY=0

  if [ "$FM_DQ_USED_TODAY" -ge "$FM_DQ_HOLD_PCT" ]; then held=1; fi
  fm_dq_baseline_write "$file" "$day" "$baseline" "$held" || { FM_DQ_REASON="cannot write $file"; FM_DQ_VERDICT=unreadable; return 1; }

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
      printf 'daily quota stop: refusing a new %s because Claude quota could not be read (%s). The daily budget cannot be checked, so the captain decides whether to proceed: grant one launch with FM_DAILY_QUOTA_ALLOW_UNREADABLE=1 (or bin/fm-daily-quota-stop.sh allow-unreadable for a hook-gated no-mistakes run), or fix quota-axi (a Claude Keychain approval may be pending).\n' \
        "$1" "$FM_DQ_REASON" ;;
  esac
}

# Consume the one-shot unreadable-quota grant. The env var covers a single
# command; the file covers a gate that runs in a hook, where no env reaches.
fm_dq_consume_unreadable_grant() {  # <fleet-home>
  local grant="$1/state/daily-quota-allow-unreadable"
  if [ "${FM_DAILY_QUOTA_ALLOW_UNREADABLE:-}" = 1 ]; then return 0; fi
  [ -f "$grant" ] || return 1
  rm -f "$grant" 2>/dev/null
}
