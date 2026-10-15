#!/usr/bin/env bash
# tests/fm-team-skills.test.sh - bin/fm-team-skills.sh links team-skills/ into the
# skills folders of a temp HOME: install is idempotent, never overwrites a real
# directory or a link pointing elsewhere, uninstall removes only its own links,
# --dry-run changes nothing, and a link it cannot create or remove exits 1.
# The opt-in `hooks enable|disable|status` edits only its two entries in settings.json.
set -u
# The real home and settings location, captured before anything is overridden.
REAL_HOME=$(cd -P -- "$HOME" && pwd -P)
REAL_SETTINGS_RAW=${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json
unset CLAUDE_CONFIG_DIR  # never let a test reach the real settings file

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-team-skills.sh"
SKILLS=$(cd -P "$ROOT/team-skills" && pwd -P)
TMP_ROOT=$(fm_test_tmproot fm-team-skills)

# Agent guard: fake codex and claude first on PATH. A real agent started under a
# throwaway HOME still reads the user's MCP config and can open sign-in pages in
# a real browser, so any launch that does not turn user MCP servers off is a
# failure, and every launch is logged for the final assertion.
AGENT_SHIMS="$TMP_ROOT/agent-shims"
AGENT_LOG="$TMP_ROOT/agent-launches.log"
mkdir -p "$AGENT_SHIMS"
: > "$AGENT_LOG"
for agent in codex claude; do
  cat > "$AGENT_SHIMS/$agent" <<SH
#!/usr/bin/env bash
printf '%s %s\n' "$agent" "\$*" >> "$AGENT_LOG"
case "$agent:\$*" in
  codex:*"mcp_servers={}"*|claude:*"--strict-mcp-config"*) exit 0 ;;
esac
echo "$agent launched without disabling user MCP servers" >&2
exit 97
SH
  chmod +x "$AGENT_SHIMS/$agent"
done
export PATH="$AGENT_SHIMS:$PATH"

new_home() {
  local h="$TMP_ROOT/$1"
  mkdir -p "$h"
  printf '%s\n' "$h"
}

# resolve_path <path>: physical path with directory and file symlinks followed,
# even when the tail does not exist yet.
resolve_path() {
  local p=$1 dir base link i=0
  while [ -L "$p" ] && [ "$i" -lt 20 ]; do
    link=$(readlink "$p")
    case "$link" in /*) p=$link ;; *) p=$(dirname "$p")/$link ;; esac
    i=$((i + 1))
  done
  dir=$(dirname "$p"); base=$(basename "$p")
  while [ ! -d "$dir" ] && [ "$dir" != / ]; do base=$(basename "$dir")/$base; dir=$(dirname "$dir"); done
  printf '%s/%s\n' "$(cd -P -- "$dir" && pwd -P)" "$base"
}

# guard_not_real <real-home> <real-settings> <home> [config-dir]: fail the test at
# once when HOME or the settings file the script would use (following symlinks) is
# the real home, inside it, or the real settings file.
guard_not_real() {
  local real=$1 real_settings=$2 h=$3 cfg=${4:-} rh settings
  rh=$(resolve_path "$h")
  settings=$(resolve_path "${cfg:-$h/.claude}/settings.json")
  case "$rh/" in "$real"/*) fail "test HOME $rh is inside the real home $real" ;; esac
  case "$settings" in "$real"/*) fail "settings path $settings resolves inside the real home $real" ;; esac
  [ "$settings" != "$(resolve_path "$real_settings")" ] || fail "settings path $settings is the real settings file"
}

REAL_SETTINGS=$(resolve_path "$REAL_SETTINGS_RAW")

run() {  # <home> <args...>: sets OUT and RC
  local h=$1; shift
  guard_not_real "$REAL_HOME" "$REAL_SETTINGS" "$h"
  OUT=$(env -u CLAUDE_CONFIG_DIR HOME="$h" "$SCRIPT" "$@" 2>&1)
  RC=$?
}

test_install_links_every_skill_into_both_folders() {
  local h name n=0; h=$(new_home fresh)
  run "$h" install
  assert_equals 0 "$RC" "install failed: $OUT"
  for src in "$SKILLS"/*/; do
    [ -f "$src/SKILL.md" ] || continue
    name=$(basename "$src"); n=$((n + 1))
    for dir in .claude/skills .agents/skills; do
      [ -L "$h/$dir/$name" ] || fail "missing link $dir/$name"
      assert_equals "${src%/}" "$(readlink "$h/$dir/$name")" "$dir/$name points elsewhere"
      assert_present "$h/$dir/$name/SKILL.md" "$dir/$name does not resolve to a skill"
    done
  done
  [ "$n" -gt 0 ] || fail "no skills found under team-skills/"
  pass "install links every skill into ~/.claude/skills and ~/.agents/skills"
}

test_install_is_idempotent() {
  local h; h=$(new_home idempotent)
  run "$h" install; run "$h" install
  assert_equals 0 "$RC" "second install failed: $OUT"
  assert_contains "$OUT" "0 new link(s)" "second install created links"
  assert_not_contains "$OUT" "Conflicts" "own links reported as conflicts"
  pass "a second install changes nothing"
}

test_install_never_overwrites_conflicts() {
  local h; h=$(new_home conflicts)
  mkdir -p "$h/.claude/skills/tdd" "$h/.agents/skills" "$h/elsewhere/diagnose"
  printf 'mine\n' > "$h/.claude/skills/tdd/SKILL.md"
  ln -s "$h/elsewhere/diagnose" "$h/.agents/skills/diagnose"
  run "$h" install
  assert_equals 0 "$RC" "install with conflicts failed: $OUT"
  assert_contains "$OUT" "$h/.claude/skills/tdd (existing file or directory)" "real directory not listed"
  assert_contains "$OUT" "$h/.agents/skills/diagnose (link to $h/elsewhere/diagnose)" "foreign link not listed"
  assert_equals mine "$(cat "$h/.claude/skills/tdd/SKILL.md")" "real directory was modified"
  assert_equals "$h/elsewhere/diagnose" "$(readlink "$h/.agents/skills/diagnose")" "foreign link was replaced"
  [ -L "$h/.claude/skills/zoom-out" ] || fail "non-conflicting skills were not installed"
  pass "install skips and lists conflicts without touching them"
}

test_uninstall_removes_only_own_links() {
  local h; h=$(new_home uninstall)
  mkdir -p "$h/.claude/skills/tdd" "$h/elsewhere/diagnose"
  ln -s "$h/elsewhere/diagnose" "$h/.claude/skills/diagnose"
  run "$h" install; run "$h" uninstall
  assert_equals 0 "$RC" "uninstall failed: $OUT"
  assert_absent "$h/.claude/skills/zoom-out" "own link survived uninstall"
  assert_absent "$h/.agents/skills/zoom-out" "own link survived uninstall"
  assert_present "$h/.claude/skills/tdd/." "real directory was removed"
  assert_equals "$h/elsewhere/diagnose" "$(readlink "$h/.claude/skills/diagnose")" "foreign link was removed"
  pass "uninstall removes only links it owns"
}

test_dry_run_changes_nothing() {
  local h; h=$(new_home dry)
  run "$h" --dry-run install
  assert_equals 0 "$RC" "dry run failed: $OUT"
  assert_contains "$OUT" "[dry-run] link" "dry run printed no plan"
  assert_absent "$h/.claude" "dry run created ~/.claude"
  assert_absent "$h/.agents" "dry run created ~/.agents"
  run "$h" install; run "$h" --dry-run uninstall
  [ -L "$h/.claude/skills/zoom-out" ] || fail "dry-run uninstall removed a link"
  pass "--dry-run changes nothing"
}

test_failed_link_or_removal_exits_1() {
  local h; h=$(new_home failing)
  mkdir -p "$h/.agents" && chmod 555 "$h/.agents"
  run "$h" install
  chmod 755 "$h/.agents"
  assert_equals 1 "$RC" "install with an unwritable ~/.agents must exit 1: $OUT"
  assert_contains "$OUT" "Failed:" "failed links not reported"
  assert_contains "$OUT" "link $h/.agents/skills/zoom-out" "failed link not listed"
  [ -L "$h/.claude/skills/zoom-out" ] || fail "writable folder was not linked"
  assert_absent "$h/.agents/skills" "unwritable folder gained a skills dir"
  run "$h" install
  assert_equals 0 "$RC" "install after fixing permissions failed: $OUT"
  chmod 555 "$h/.claude/skills"
  run "$h" uninstall
  chmod 755 "$h/.claude/skills"
  assert_equals 1 "$RC" "uninstall with an unwritable folder must exit 1: $OUT"
  assert_contains "$OUT" "remove $h/.claude/skills/zoom-out" "failed removal not listed"
  [ -L "$h/.claude/skills/zoom-out" ] || fail "link vanished despite failed removal"
  assert_absent "$h/.agents/skills/zoom-out" "writable folder link survived uninstall"
  pass "a link the script could not create or remove exits 1"
}

test_installed_links_resolve_to_loadable_skills() {
  # Inspect the links instead of launching an agent: each installed skill must
  # resolve to a SKILL.md whose frontmatter name matches its folder.
  local h name f; h=$(new_home loadable)
  run "$h" install
  for f in "$h"/.claude/skills/* "$h"/.agents/skills/*; do
    name=$(basename "$f")
    assert_present "$f/SKILL.md" "$name does not resolve to a SKILL.md"
    assert_equals "name: $name" "$(sed -n '2,6p' "$f/SKILL.md" | grep -m1 '^name:')" "$name frontmatter name differs from its folder"
  done
  pass "installed links resolve to skills whose name matches the folder"
}

test_no_agent_was_launched() {
  assert_equals 0 "$(wc -l < "$AGENT_LOG" | tr -d ' ')" "a test launched a real agent: $(cat "$AGENT_LOG")"
  pass "no test launches codex or claude"
}

test_bad_usage_exits_2() {
  local h; h=$(new_home usage)
  run "$h"; assert_equals 2 "$RC" "no command must exit 2"
  run "$h" frobnicate; assert_equals 2 "$RC" "unknown argument must exit 2"
  pass "bad usage exits 2"
}

test_every_skill_carries_license_or_credit() {
  local d name
  for d in "$ROOT"/team-skills/*/; do
    [ -f "$d/SKILL.md" ] || continue
    name=$(basename "$d")
    assert_present "$d/SOURCE" "$name has no SOURCE note"
    [ -f "$d/LICENSE" ] || assert_grep "Credit:" "$d/SOURCE" "$name has neither LICENSE nor a credit line"
  done
  pass "every skill has a SOURCE note and a LICENSE or credit line"
}

EXPLAIN_CMD="$SKILLS/hooks/explain-with-example.sh"
STOP_CMD="$SKILLS/hooks/no-raw-diagrams.py"

count_backups() { find "$1/.claude" -maxdepth 1 -name 'settings.json.bak-*' | wc -l | tr -d ' '; }

settings_of() { printf '%s/.claude/settings.json\n' "$1"; }

seed_settings() {  # <home> <json>
  mkdir -p "$1/.claude"; printf '%s\n' "$2" > "$(settings_of "$1")"
}

OTHER='{"theme":"dark","env":{"A":"1"},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"mine-stop"}]}],"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"mine-pre"}]}]}}'

test_install_never_touches_settings() {
  local h; h=$(new_home hooks-install)
  seed_settings "$h" "$OTHER"
  run "$h" install; run "$h" uninstall
  assert_equals "$(printf '%s\n' "$OTHER")" "$(cat "$(settings_of "$h")")" "install/uninstall changed settings.json"
  assert_equals 0 "$(count_backups "$h")" "install/uninstall wrote a backup"
  pass "install and uninstall never touch settings.json"
}

test_hooks_enable_adds_exactly_our_entries() {
  local h f; h=$(new_home hooks-enable); f=$(settings_of "$h")
  seed_settings "$h" "$OTHER"
  run "$h" hooks status
  assert_contains "$OUT" "explain-with-example.sh (UserPromptSubmit): off" "status before enable"
  run "$h" hooks enable
  assert_equals 0 "$RC" "enable failed: $OUT"
  assert_equals "$EXPLAIN_CMD" "$(jq -r '.hooks.UserPromptSubmit[0].hooks[0].command' "$f")" "UserPromptSubmit entry wrong"
  assert_equals "$STOP_CMD" "$(jq -r '.hooks.Stop[1].hooks[0].command' "$f")" "Stop entry not appended"
  assert_equals "$(printf '%s' "$OTHER" | jq -cS 'del(.hooks.UserPromptSubmit)|del(.hooks.Stop[1])')" \
    "$(jq -cS 'del(.hooks.UserPromptSubmit)|del(.hooks.Stop[1])' "$f")" "enable changed something else"
  assert_equals 1 "$(count_backups "$h")" "enable made no backup"
  assert_equals "$OTHER" "$(cat "$h/.claude"/settings.json.bak-*)" "backup differs from the original"
  run "$h" hooks status
  assert_contains "$OUT" "no-raw-diagrams.py (Stop): on" "status after enable"
  pass "hooks enable adds exactly the two entries and backs up the original"
}

test_hooks_enable_is_idempotent() {
  local h before; h=$(new_home hooks-idem)
  seed_settings "$h" "$OTHER"
  run "$h" hooks enable
  before=$(cat "$(settings_of "$h")")
  run "$h" hooks enable
  assert_equals 0 "$RC" "re-enable failed: $OUT"
  assert_contains "$OUT" "nothing to change" "re-enable did not report a no-op"
  assert_equals "$before" "$(cat "$(settings_of "$h")")" "re-enable changed the file"
  assert_equals 1 "$(count_backups "$h")" "re-enable made another backup"
  pass "re-enabling is a no-op"
}

test_hooks_enable_creates_missing_settings() {
  local h; h=$(new_home hooks-fresh)
  run "$h" hooks enable
  assert_equals 0 "$RC" "enable on a fresh home failed: $OUT"
  assert_equals 2 "$(jq '[.hooks[][]] | length' "$(settings_of "$h")")" "fresh enable did not add two entries"
  run "$h" hooks disable
  assert_equals '{}' "$(jq -c . "$(settings_of "$h")")" "disable did not leave an empty object"
  pass "enable creates settings.json and disable empties it again"
}

test_hooks_disable_removes_only_ours() {
  local h f; h=$(new_home hooks-disable); f=$(settings_of "$h")
  seed_settings "$h" "$OTHER"
  run "$h" hooks enable
  # A user hook sharing our entry, and a hook of ours moved to another clone path.
  jq '.hooks.Stop[1].hooks += [{"type":"command","command":"mine-too"}]
      | .hooks.UserPromptSubmit[0].hooks[0].command = "/elsewhere/team-skills/hooks/explain-with-example.sh"' "$f" > "$f.new" && mv "$f.new" "$f"
  run "$h" hooks disable
  assert_equals 0 "$RC" "disable failed: $OUT"
  assert_equals "$(printf '%s' "$OTHER" | jq -cS '.hooks.Stop[1].hooks=[{"type":"command","command":"mine-too"}]')" \
    "$(jq -cS . "$f")" "disable removed or kept the wrong entries"
  run "$h" hooks disable
  assert_contains "$OUT" "nothing to change" "second disable was not a no-op"
  pass "hooks disable removes only our entries and keeps every other hook"
}

test_hooks_refuse_bad_settings() {
  local h bad
  for bad in 'not json {' '[1,2]' '{"hooks":[]}' '{"hooks":{"Stop":{}}}'; do
    h=$(new_home "hooks-bad-$RANDOM"); seed_settings "$h" "$bad"
    for sub in enable disable status; do
      run "$h" hooks "$sub"
      assert_equals 1 "$RC" "$sub on '$bad' must exit 1: $OUT"
      assert_contains "$OUT" "refusing to touch" "$sub on '$bad' gave no refusal"
    done
    assert_equals "$bad" "$(cat "$(settings_of "$h")")" "settings changed despite refusal"
    assert_equals 0 "$(count_backups "$h")" "refusal left a backup"
  done
  pass "hooks refuse unparseable or misshapen settings and leave them alone"
}

test_hooks_keep_symlinked_settings() {
  local h; h=$(new_home hooks-link)
  mkdir -p "$h/.claude" "$h/real"; printf '%s\n' "$OTHER" > "$h/real/settings.json"
  ln -s "$h/real/settings.json" "$h/.claude/settings.json"
  run "$h" hooks enable
  [ -L "$h/.claude/settings.json" ] || fail "enable replaced the settings symlink"
  assert_equals 2 "$(jq '[.. | objects | select(.command? | strings | contains("/team-skills/hooks/"))] | length' "$h/real/settings.json")" "target not updated"
  run "$h" hooks disable
  assert_equals "$(printf '%s' "$OTHER" | jq -cS .)" "$(jq -cS . "$h/real/settings.json")" "disable did not restore the target"
  pass "a symlinked settings file stays a link and its target is edited"
}

test_hooks_dry_run_and_config_dir() {
  local h; h=$(new_home hooks-dry)
  seed_settings "$h" "$OTHER"
  run "$h" --dry-run hooks enable
  assert_contains "$OUT" "[dry-run] enable hooks" "dry run printed no plan"
  assert_equals "$OTHER" "$(cat "$(settings_of "$h")")" "dry run changed settings"
  guard_not_real "$REAL_HOME" "$REAL_SETTINGS" "$h" "$h/cfg"
  OUT=$(env HOME="$h" CLAUDE_CONFIG_DIR="$h/cfg" "$SCRIPT" hooks enable 2>&1); RC=$?
  assert_equals 0 "$RC" "enable with CLAUDE_CONFIG_DIR failed: $OUT"
  assert_present "$h/cfg/settings.json" "CLAUDE_CONFIG_DIR was ignored"
  assert_equals "$OTHER" "$(cat "$(settings_of "$h")")" "default settings touched despite CLAUDE_CONFIG_DIR"
  pass "--dry-run changes nothing and CLAUDE_CONFIG_DIR selects the settings file"
}

test_hook_scripts_behave() {
  local out
  out=$(printf '%s' '{"prompt":"please explain the flow"}' | "$EXPLAIN_CMD")
  assert_contains "$out" "TEAM RULE" "explain hook silent on an explain prompt"
  assert_not_contains "$out" "CAPTAIN" "explain hook kept a personal label"
  out=$(printf '%s' '{"prompt":"rename the variable"}' | "$EXPLAIN_CMD")
  assert_equals "" "$out" "explain hook fired on an unrelated prompt"
  local tr="$TMP_ROOT/transcript.jsonl"
  printf '%s\n' '{"type":"user","message":{"content":"hi"}}' \
    '{"type":"assistant","message":{"content":[{"type":"text","text":"a<br/>b"}]}}' > "$tr"
  out=$(jq -n --arg t "$tr" '{transcript_path:$t}' | python3 -I "$STOP_CMD")
  assert_contains "$out" '"decision": "block"' "stop hook missed a raw <br/>"
  out=$(jq -n --arg t "$tr" '{transcript_path:$t,stop_hook_active:true}' | python3 -I "$STOP_CMD")
  assert_equals "" "$out" "stop hook looped"
  pass "the two hook scripts fire only when they should"
}

test_guard_trips_on_the_real_home() {
  # A fake "real home" in temp stands in for the actual one; nothing real is touched.
  local fake out; fake=$(new_home guard-fake-real); fake=$(cd -P -- "$fake" && pwd -P)
  mkdir -p "$fake/.claude" "$fake/sub" "$TMP_ROOT/guard-safe" "$TMP_ROOT/guard-link/.claude"
  : > "$fake/.claude/settings.json"
  ln -s "$fake/.claude/settings.json" "$TMP_ROOT/guard-link/.claude/settings.json"
  ( guard_not_real "$fake" "$fake/.claude/settings.json" "$fake" ) >/dev/null 2>&1 && fail "guard passed HOME equal to the real home"
  ( guard_not_real "$fake" "$fake/.claude/settings.json" "$fake/sub" ) >/dev/null 2>&1 && fail "guard passed a HOME inside the real home"
  ( guard_not_real "$fake" "$fake/.claude/settings.json" "$TMP_ROOT/guard-safe" "$fake/.claude" ) >/dev/null 2>&1 && fail "guard passed a config dir inside the real home"
  out=$( ( guard_not_real "$fake" "$fake/.claude/settings.json" "$TMP_ROOT/guard-link" ) 2>&1 ) && fail "guard passed a symlink into the real settings"
  assert_contains "$out" "resolves inside the real home" "symlink refusal gave the wrong reason"
  ( guard_not_real "$fake" "$fake/.claude/settings.json" "$TMP_ROOT/guard-safe" ) >/dev/null 2>&1 || fail "guard refused a safe temp HOME"
  # The real settings file outside the real home (CLAUDE_CONFIG_DIR plus a symlink).
  mkdir -p "$TMP_ROOT/guard-elsewhere" "$TMP_ROOT/guard-cfg"
  : > "$TMP_ROOT/guard-elsewhere/settings.json"
  ln -s "$TMP_ROOT/guard-elsewhere/settings.json" "$TMP_ROOT/guard-cfg/settings.json"
  out=$( ( guard_not_real "$fake" "$TMP_ROOT/guard-elsewhere/settings.json" "$TMP_ROOT/guard-safe" "$TMP_ROOT/guard-cfg" ) 2>&1 ) && fail "guard passed a link to the real settings file"
  assert_contains "$out" "is the real settings file" "real-settings refusal gave the wrong reason"
  pass "the real-home guard trips on the real HOME, config dir and symlinks, and passes a temp HOME"
}

if [ -n "${FM_TEST_ONLY:-}" ]; then
  "$FM_TEST_ONLY"
else
  test_install_links_every_skill_into_both_folders
  test_install_is_idempotent
  test_install_never_overwrites_conflicts
  test_uninstall_removes_only_own_links
  test_dry_run_changes_nothing
  test_failed_link_or_removal_exits_1
  test_installed_links_resolve_to_loadable_skills
  test_bad_usage_exits_2
  test_every_skill_carries_license_or_credit
  test_guard_trips_on_the_real_home
  test_install_never_touches_settings
  test_hooks_enable_adds_exactly_our_entries
  test_hooks_enable_is_idempotent
  test_hooks_enable_creates_missing_settings
  test_hooks_disable_removes_only_ours
  test_hooks_refuse_bad_settings
  test_hooks_keep_symlinked_settings
  test_hooks_dry_run_and_config_dir
  test_hook_scripts_behave
  test_no_agent_was_launched
fi
