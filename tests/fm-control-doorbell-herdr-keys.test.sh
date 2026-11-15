#!/usr/bin/env bash
# Fork-only: tests/fm-control-doorbell-herdr-keys.test.sh - the clipped-doorbell
# front trim on the herdr backend (applypass fork).
#
# The trim in bin/fm-control-doorbell-lib.sh names its keys in tmux's words and
# maps them to herdr's. herdr 0.9.x refuses a name it does not know with
# `invalid_key` (verified live: delete, Delete, del and DC all refuse), so one
# wrong name makes every herdr clear refuse. This drives the real trim through
# the real herdr adapter, with only the herdr CLI replaced by a model of a
# clipped Claude composer that accepts exactly the key names verified live on
# herdr 0.9.5 with Claude 2.1.325: ctrl+a, backspace and ctrl+d (one character
# forward). Canned model only - never a real herdr session.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-control-doorbell-lib.sh"
fm_backend_source herdr || fail "the herdr adapter should source"

MODEL=$(mktemp -d "${TMPDIR:-/tmp}/fm-doorbell-herdr.XXXXXX")
trap 'rm -rf "$MODEL"' EXIT

# Transport stand-ins: the pane is always there, and every CLI call reaches the
# model below.
fm_backend_herdr_target_ready() { FM_BACKEND_HERDR_SESSION=fm-test; FM_BACKEND_HERDR_PANE=w1:p1; }
fm_backend_herdr_target_observable() { fm_backend_herdr_target_ready; }
fm_backend_herdr_cli() {  # <session> pane <verb> <pane> [arg...]
  local text cur
  text=$(cat "$MODEL/composer")
  cur=$(cat "$MODEL/cursor")
  case "$2 $3" in
    'pane send-keys')
      printf '%s\n' "$5" >> "$MODEL/keys"
      case "$5" in
        ctrl+a) printf 0 > "$MODEL/cursor" ;;
        backspace)
          [ "$cur" -gt 0 ] || return 0
          printf '%s%s' "${text:0:cur-1}" "${text:cur}" > "$MODEL/composer"
          printf '%s' "$((cur - 1))" > "$MODEL/cursor" ;;
        ctrl+d) printf '%s%s' "${text:0:cur}" "${text:cur+1}" > "$MODEL/composer" ;;
        *)
          printf '{"error":{"code":"invalid_key","message":"unsupported key %s"}}\n' "$5"
          return 1 ;;
      esac ;;
    'pane send-text')
      printf '%s%s%s' "${text:0:cur}" "$5" "${text:cur}" > "$MODEL/composer"
      printf '%s' "$((cur + ${#5}))" > "$MODEL/cursor" ;;
    'pane read')
      # A pane too short for every wrapped row shows only the first one, with
      # nothing drawn under it; an empty composer shows its closed box.
      if [ -n "$text" ]; then
        printf '%s\n❯ %s\n' '──────────────────────────────' "$(printf '%s' "$text" | fold -s -w 120 | head -1)"
      else
        printf '╭────╮\n│    │\n╰────╯\n'
      fi ;;
    *) return 1 ;;
  esac
}

line=$(fm_task_inbox_doorbell_line "/state/release-delay-rca.inbox/x.msg")
BACKEND=herdr T=fm-test:w1:p1 LABEL= POLL=0

# shellcheck disable=SC2329,SC2317
sleep() { :; }

test_herdr_clears_a_clipped_own_doorbell() {
  printf '%s' "$line" > "$MODEL/composer"; printf '%s' "${#line}" > "$MODEL/cursor"; : > "$MODEL/keys"
  fm_control_composer_holds_truncated_doorbell herdr "$T" "$line" \
    || fail "the model should show a clipped view the matcher accepts"
  fm_control_trim_clipped_doorbell "$line" \
    || fail "the clipped own doorbell should clear on herdr; keys sent: $(tr '\n' ' ' < "$MODEL/keys")"
  [ ! -s "$MODEL/composer" ] || fail "the composer should be empty, holds: $(cat "$MODEL/composer")"
  pass "herdr: a clipped own doorbell is trimmed from the front with keys herdr accepts"
}

test_herdr_keeps_text_typed_after_a_clipped_doorbell() {
  printf '%s ALSO MY OWN DRAFT keep me' "$line" > "$MODEL/composer"
  printf '%s' "$(wc -c < "$MODEL/composer" | tr -d ' ')" > "$MODEL/cursor"; : > "$MODEL/keys"
  if fm_control_trim_clipped_doorbell "$line"; then
    fail "text after a clipped doorbell must refuse"
  fi
  case "$(cat "$MODEL/composer")" in
    *"ALSO MY OWN DRAFT keep me") ;;
    *) fail "text after a clipped doorbell must survive, composer holds: $(cat "$MODEL/composer")" ;;
  esac
  pass "herdr: text typed after a clipped doorbell survives"
}

fm_test_run \
  test_herdr_clears_a_clipped_own_doorbell \
  test_herdr_keeps_text_typed_after_a_clipped_doorbell
