# shellcheck shell=bash disable=SC2034
# Fork-only (applypass): plain-shell detection of an agent stopped at a usage
# limit. Sourced by bin/fm-usage-limit.sh and bin/fm-usage-limit-tick.sh; owns
# the screen markers, the reset-time parse, the option-menu key choice, and the
# quota fallback. No state is read or written here.
#
# fm_usage_limit_detect <screen-text> [now-epoch]
#   Sets, for the caller to read:
#     FM_UL_STOPPED  1 when the bottom of the screen is a usage-limit stop, else 0
#     FM_UL_KIND     limit | credits | wait | ""
#     FM_UL_RESET    reset epoch parsed from the screen (honoring a shown
#                    timezone), or "" when none could be parsed
#     FM_UL_KEY      "" (no menu), Enter (the highlighted option waits), or
#                    Escape (the highlighted option is not a plain wait)
#
# Only the last FM_UL_TAIL_LINES non-blank lines count, so a page of output that
# merely mentions a limit (an agent editing this file) is not a stop.

set -u

FM_UL_TAIL_LINES=${FM_UL_TAIL_LINES:-15}
# An option that spends money or changes the plan. It is never chosen.
FM_UL_PAID_RE='credit|extra usage|upgrade|add funds|buy|purchase|billing|overage|top.?up|subscribe|pay'
# An option that waits or dismisses.
FM_UL_WAIT_RE='wait|stop|continue automatically|later|dismiss|cancel'

fm_ul_tail() {  # <text>
  printf '%s\n' "$1" | grep -v '^[[:space:]]*$' | tail -n "$FM_UL_TAIL_LINES"
}

fm_ul_month_number() {  # <3-letter month, any case>
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    jan) echo 1 ;; feb) echo 2 ;; mar) echo 3 ;; apr) echo 4 ;; may) echo 5 ;; jun) echo 6 ;;
    jul) echo 7 ;; aug) echo 8 ;; sep) echo 9 ;; oct) echo 10 ;; nov) echo 11 ;; dec) echo 12 ;;
    *) return 1 ;;
  esac
}

# fm_ul_epoch <tz-or-empty> <YYYY-MM-DD> <HH:MM>: epoch of that wall time.
fm_ul_epoch() {
  local tz=$1 day=$2 hm=$3
  if date --version >/dev/null 2>&1; then
    if [ -n "$tz" ]; then TZ=$tz date -d "$day $hm" +%s 2>/dev/null; else date -d "$day $hm" +%s 2>/dev/null; fi
  else
    if [ -n "$tz" ]; then
      TZ=$tz date -j -f '%Y-%m-%d %H:%M:%S' "$day $hm:00" +%s 2>/dev/null
    else
      date -j -f '%Y-%m-%d %H:%M:%S' "$day $hm:00" +%s 2>/dev/null
    fi
  fi
}

fm_ul_today() {  # <tz-or-empty> <now-epoch> <format>
  if date --version >/dev/null 2>&1; then
    if [ -n "$1" ]; then TZ=$1 date -d "@$2" "+$3"; else date -d "@$2" "+$3"; fi
  else
    if [ -n "$1" ]; then TZ=$1 date -r "$2" "+$3"; else date -r "$2" "+$3"; fi
  fi
}

# fm_usage_limit_parse_reset <text> <now>: print the reset epoch, or fail.
# Reads the lines bottom-up, so the newest banner wins.
fm_usage_limit_parse_reset() {
  local text=$1 now=$2 line hour min ampm tz mon day mnum year cand h24 hm d
  local re_abs='resets?[[:space:]]+(at[[:space:]]+)?(([A-Za-z]{3})[A-Za-z]*\.?[[:space:]]+([0-9]{1,2})(st|nd|rd|th)?,?[[:space:]]+(at[[:space:]]+)?)?([0-9]{1,2})(:([0-9]{2}))?[[:space:]]*(am|pm)([[:space:]]*\(([A-Za-z][A-Za-z0-9_/+-]*)\))?'
  local re_rel='resets?[[:space:]]+in[[:space:]]+(([0-9]+)[[:space:]]*h[a-z]*)?[[:space:]]*(([0-9]+)[[:space:]]*m[a-z]*)?'
  local had_nocase=0
  shopt -q nocasematch && had_nocase=1
  shopt -s nocasematch
  while IFS= read -r line; do
    [[ $line == *reset* ]] || continue
    if [[ $line =~ $re_abs ]]; then
      mon=${BASH_REMATCH[3]} day=${BASH_REMATCH[4]} hour=${BASH_REMATCH[7]}
      min=${BASH_REMATCH[9]:-00} ampm=${BASH_REMATCH[10]} tz=${BASH_REMATCH[12]:-}
      [ "$hour" -ge 1 ] 2>/dev/null && [ "$hour" -le 12 ] || continue
      ampm=$(printf '%s' "$ampm" | tr '[:upper:]' '[:lower:]')
      h24=$((10#$hour % 12))
      [ "$ampm" = pm ] && h24=$((h24 + 12))
      hm=$(printf '%02d:%s' "$h24" "$min")
      if [ -n "$mon" ] && mnum=$(fm_ul_month_number "$mon"); then
        year=$(fm_ul_today "$tz" "$now" %Y)
        d=$(printf '%s-%02d-%02d' "$year" "$mnum" "$((10#$day))")
        cand=$(fm_ul_epoch "$tz" "$d" "$hm") || continue
        [ "$cand" -ge $((now - 86400)) ] || cand=$(fm_ul_epoch "$tz" "$(printf '%s-%02d-%02d' "$((year + 1))" "$mnum" "$((10#$day))")" "$hm") || continue
      else
        d=$(fm_ul_today "$tz" "$now" %Y-%m-%d)
        cand=$(fm_ul_epoch "$tz" "$d" "$hm") || continue
        [ "$cand" -gt $((now - 60)) ] || cand=$((cand + 86400))
      fi
      [ "$had_nocase" = 1 ] || shopt -u nocasematch
      printf '%s\n' "$cand"
      return 0
    fi
    if [[ $line =~ $re_rel ]] && { [ -n "${BASH_REMATCH[2]}" ] || [ -n "${BASH_REMATCH[4]}" ]; }; then
      cand=$((now + 3600 * 10#${BASH_REMATCH[2]:-0} + 60 * 10#${BASH_REMATCH[4]:-0}))
      [ "$had_nocase" = 1 ] || shopt -u nocasematch
      printf '%s\n' "$cand"
      return 0
    fi
  done < <(printf '%s\n' "$text" | awk '{ a[NR] = $0 } END { for (i = NR; i >= 1; i--) print a[i] }')
  [ "$had_nocase" = 1 ] || shopt -u nocasematch
  return 1
}

# fm_usage_limit_menu_key <tail>: Enter, Escape, or empty (no menu).
# A numbered option list is a menu. Enter is sent only when the highlighted
# option waits and does not spend money; every other highlight gets Escape.
fm_usage_limit_menu_key() {
  local tail=$1 opts=0 highlighted='' line
  while IFS= read -r line; do
    if [[ $line =~ ^[[:space:]]*([❯›\>]?)[[:space:]]*[0-9]+[.\)][[:space:]]+(.*)$ ]]; then
      opts=$((opts + 1))
      [ -z "${BASH_REMATCH[1]}" ] || highlighted=${BASH_REMATCH[2]}
    fi
  done <<< "$tail"
  [ "$opts" -ge 2 ] || return 0
  if [ -n "$highlighted" ] \
    && ! printf '%s' "$highlighted" | grep -Eiq "$FM_UL_PAID_RE" \
    && printf '%s' "$highlighted" | grep -Eiq "$FM_UL_WAIT_RE"; then
    echo Enter
  else
    echo Escape
  fi
}

fm_usage_limit_detect() {  # <screen-text> [now]
  local text=$1 now=${2:-$(date +%s)} tail
  FM_UL_STOPPED=0 FM_UL_KIND='' FM_UL_RESET='' FM_UL_KEY=''
  tail=$(fm_ul_tail "$text")
  # A banner never carries double quotes or backticks; a quoted marker is code or a command.
  tail=$(printf '%s\n' "$tail" | grep -v '["`]')
  if printf '%s\n' "$tail" | grep -Eiq 'out of usage credits'; then
    FM_UL_KIND=credits
  elif printf '%s\n' "$tail" | grep -Eiq "(usage|session|weekly|5-hour|[0-9]+-hour|opus|sonnet)? ?limit reached|hit your( [a-z0-9-]+)? limit|usage limit.*(reset|reached)|limit will reset"; then
    FM_UL_KIND=limit
  elif printf '%s\n' "$tail" | grep -Eiq 'stop and wait for limit to reset|wait here, then continue automatically'; then
    FM_UL_KIND='wait'
  else
    return 0
  fi
  FM_UL_STOPPED=1
  FM_UL_RESET=$(fm_usage_limit_parse_reset "$tail" "$now" 2>/dev/null || true)
  FM_UL_KEY=$(fm_usage_limit_menu_key "$tail")
}

# fm_usage_limit_quota_reset <harness> <now>: print a reset epoch read from
# quota-axi, or fail. Read-only (--no-credential-refresh). An exhausted window
# wins; with none exhausted, the five_hour window is the best evidence.
fm_usage_limit_quota_reset() {
  local harness=$1 now=$2 provider json
  command -v quota-axi >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || return 1
  if [ -z "${FM_QUOTA_AXI_MIN:-}" ]; then
    # shellcheck source=bin/fm-quota-axi-lib.sh
    . "$(dirname "${BASH_SOURCE[0]}")/fm-quota-axi-lib.sh"
  fi
  provider=$(fm_quota_provider_for_harness "$harness" "${3:-}") || return 1
  if [ "$(type -t fm_run_timed)" = function ]; then
    json=$(fm_run_timed 10 quota-axi --provider "$provider" --json --no-credential-refresh 2>/dev/null </dev/null) || return 1
  else
    json=$(quota-axi --provider "$provider" --json --no-credential-refresh 2>/dev/null </dev/null) || return 1
  fi
  printf '%s' "$json" | jq -er --argjson now "$now" --arg provider "$provider" '
    def ts: sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601;
    [.providers[]? | select(.provider == $provider) | .windows[]?
      | select(.id == "five_hour" or .id == "seven_day")
      | select(.resetsAt != null)
      | {id, left: .percentRemaining, at: (.resetsAt | ts)}
      | select(.at > $now)] as $w
    | ([$w[] | select(.left == 0)] | map(.at) | max)
      // ([$w[] | select(.id == "five_hour")] | map(.at) | min)
      // ([$w[].at] | min)
  ' 2>/dev/null
}
