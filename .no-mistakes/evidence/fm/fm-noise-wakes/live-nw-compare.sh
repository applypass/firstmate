#!/usr/bin/env bash
# Steps 1-2: the same quota refusal and re-block, through the base and the target code.
set -u
for ROOT in "$@"; do
  cd "$ROOT"; echo "##### code at: $(basename "$ROOT")"
  unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_STATE_OVERRIDE FM_NEVER_WAIT FM_DAILY_QUOTA_STOP
  LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); FAKE=$(mktemp -d)
  bin/fm-lab-home.sh create "$LAB" >/dev/null 2>&1 || mkdir -p "$LAB/state" "$LAB/data" "$LAB/config"
  printf '#!/usr/bin/env bash\njq -n --argjson rem "$((100 - ${FAKE_QUOTA_USED:-0}))" '"'"'{schemaVersion: 5, providers: [{provider: "claude", state: {status: "fresh", stale: false}, windows: [{id: "seven_day", kind: "weekly", resetsAt: "2026-11-09T00:00:00.000000+00:00", percentRemaining: $rem}]}]}'"'"'\n' > "$FAKE/quota-axi"; chmod +x "$FAKE/quota-axi"
  export PATH="$FAKE:$PATH" FM_HOME=$LAB; S=$LAB/state; NOW=$(date +%s)
  LATER=$(TZ=UTC date -r $((NOW+7200)) +%Y-%m-%dT%H:%MZ)
  : > "$S/mate1.meta"; : > "$S/mate1.status"
  FAKE_QUOTA_USED=10 FM_DAILY_QUOTA_NOW=$((NOW-1)) bin/fm-daily-quota-stop.sh check spawn --home "$LAB" --status-file "$S/mate1.status" 2>/dev/null
  FAKE_QUOTA_USED=31 bin/fm-daily-quota-stop.sh check spawn --home "$LAB" --status-file "$S/mate1.status" 2>/dev/null
  echo "quota line: $(cat "$S/mate1.status")"
  : > "$S/mate2.meta"
  printf 'blocked [at=%s]: waiting on stuff\n' "$NOW" > "$S/mate2.status"
  printf 'blocked [at=%s]: external-wait until=%s: vendor fix in flight\n' "$((NOW+60))" "$LATER" >> "$S/mate2.status"
  echo "sweep findings: $(bin/fm-never-wait.sh sweep --now $((NOW+120)) | sed 's/ | /\n  /g')"
  rm -rf "$LAB" "$FAKE"; echo
done
