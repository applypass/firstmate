#!/usr/bin/env bash
# Live end-to-end driver for the context-measure-lib adoption change.
# Stands up an isolated primary firstmate home and invokes the REAL hooks
# (bin/fm-context-budget.sh Stop hook and bin/fm-session-pulse.sh Stop hook)
# exactly as Claude Code invokes them: payload JSON on stdin, --claude mode.
set -u
WT=/Users/uayyagari/.no-mistakes/worktrees/c5d69c01912a/01M2TVDSXM0QVT7SKEQ0E92XWS
EV=/Users/uayyagari/.no-mistakes/evidence/01M2TVDSXM0QVT7SKEQ0E92XWS
HOME_DIR="$EV/home"
rm -rf "$HOME_DIR"; mkdir -p "$HOME_DIR/bin" "$HOME_DIR/state"
git init -q "$HOME_DIR"; git -C "$HOME_DIR" commit -q --allow-empty -m init
: > "$HOME_DIR/AGENTS.md"
cp "$WT/bin/"*.sh "$HOME_DIR/bin/" 2>/dev/null
chmod +x "$HOME_DIR/bin/"*.sh
T="$HOME_DIR/t"; mkdir -p "$T"

aline() { # total requestId sidechain
  printf '{"type":"assistant","isSidechain":%s,"requestId":"%s","message":{"model":"claude-opus-5","usage":{"input_tokens":2,"cache_creation_input_tokens":8,"cache_read_input_tokens":%s,"output_tokens":10}}}\n' \
    "${3:-false}" "${2:-req}" "$(( $1 - 20 ))"
}
compact() { printf '{"type":"system","subtype":"compact_boundary","isSidechain":false,"compactMetadata":{"preTokens":318961,"postTokens":18947}}\n'; }
payload() { printf '{"session_id":"%s","stop_hook_active":false,"transcript_path":"%s"}' "$2" "$1"; }
budget() { # transcript sess enforce extra...
  local tr=$1 sess=$2; shift 2
  printf '%s' "$(payload "$tr" "$sess")" | env "$@" CLAUDECODE=1 FM_HOME="$HOME_DIR" \
    bash "$HOME_DIR/bin/fm-context-budget.sh" --claude
}
pulse() { local tr=$1 sess=$2; shift 2
  printf '%s' "$(payload "$tr" "$sess")" | env "$@" CLAUDECODE=1 FM_HOME="$HOME_DIR" \
    bash "$HOME_DIR/bin/fm-session-pulse.sh" --claude
}
hr() { printf '\n================ %s ================\n' "$1"; }

hr "A: over-ceiling turn BLOCKS under enforcement (exit 2), names /stow + handover"
aline 210000 req-a > "$T/a.jsonl"
out=$(budget "$T/a.jsonl" sess-a FM_CONTEXT_BUDGET_ENFORCE=1 FM_CONTEXT_BUDGET_CEILING=180000); rc=$?
echo "exit=$rc"; echo "$out"

hr "B: multi-block turn - sum(100k+100k)=200k>ceiling, but LAST block 50k<advisory => NOT blocked"
{ aline 100000 req-b1; aline 100000 req-b1; aline 50000 req-b1; } > "$T/b.jsonl"
out=$(budget "$T/b.jsonl" sess-b FM_CONTEXT_BUDGET_ENFORCE=1 FM_CONTEXT_BUDGET_CEILING=180000); rc=$?
echo "exit=$rc  (0 = correct: measured last block, not the 250k sum)"; echo "${out:-<silent>}"

hr "C: sidechain exclusion - 999,999-token SIDECHAIN line + 50k main => NOT blocked"
{ aline 999999 req-sc true; aline 50000 req-c; } > "$T/c.jsonl"
out=$(budget "$T/c.jsonl" sess-c FM_CONTEXT_BUDGET_ENFORCE=1 FM_CONTEXT_BUDGET_CEILING=180000); rc=$?
echo "exit=$rc  (0 = correct: subagent turn never inflates the primary)"; echo "${out:-<silent>}"

hr "D: genuine reset - pre-compaction 300k, boundary, post-compaction 20k => LAST wins, NOT blocked"
{ aline 300000 req-d1; compact; aline 20000 req-d2; } > "$T/d.jsonl"
out=$(budget "$T/d.jsonl" sess-d FM_CONTEXT_BUDGET_ENFORCE=1 FM_CONTEXT_BUDGET_CEILING=180000); rc=$?
echo "exit=$rc  (0 = correct: compaction reset, last total 20k, guard fell back below ceiling)"; echo "${out:-<silent>}"

hr "E: session-pulse reports the SAME measurement from the shared lib (handover-due notice)"
aline 250000 req-e > "$T/e.jsonl"
out=$(pulse "$T/e.jsonl" sess-e); rc=$?
echo "exit=$rc"; echo "$out" | jq -r '.systemMessage' 2>/dev/null || echo "$out"

hr "F: single-owner check - the guard carries NO inline measurement copy"
if grep -q "fm_context_measure_transcript" "$HOME_DIR/bin/fm-context-budget.sh" \
   && ! grep -qE 'measure_context\(\)|def usage_total' "$HOME_DIR/bin/fm-context-budget.sh"; then
  echo "guard calls fm_context_measure_transcript and defines no private formula: OK"
else
  echo "UNEXPECTED: guard still holds a private formula"
fi
