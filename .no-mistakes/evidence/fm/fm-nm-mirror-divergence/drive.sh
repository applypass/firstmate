#!/usr/bin/env bash
# Live driver: real fm-op-guard-install.sh + real claude -p against throwaway repos.
set -u
REPO=/Users/uayyagari/.no-mistakes/worktrees/c5d69c01912a/01M5BWSRGG7BVH8QZ2MVX509X4
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
mkdir -p "$LAB/shim"
cat > "$LAB/shim/no-mistakes" <<'S'
#!/bin/sh
echo "SHIM-NO-MISTAKES-REACHED args: $*"
S
chmod +x "$LAB/shim/no-mistakes"

setup() { # <name> -> W GATE
  local d="$LAB/$1"; FORGE="$d/forge.git"; GATE="$d/gate.git"; W="$d/wt"
  mkdir -p "$d"; git init -q --bare -b main "$FORGE"; git init -q --bare -b main "$GATE"
  git init -q -b main "$W"; git -C "$W" remote add origin "$FORGE"; git -C "$W" remote add no-mistakes "$GATE"
  echo base > "$W/a"; git -C "$W" add a; git -C "$W" commit -qm base; git -C "$W" push -q origin main
  git -C "$W" checkout -q -b feat; echo one > "$W/b"; git -C "$W" add b; git -C "$W" commit -qm "feat: one"
  git -C "$W" push -q origin feat; git -C "$W" push -q no-mistakes feat
  # main moves on, worker rebases
  git -C "$W" checkout -q main; echo m2 > "$W/m"; git -C "$W" add m; git -C "$W" commit -qm m2; git -C "$W" checkout -q feat
}

claude_try() { # <label> <command>
  echo "=== claude: $1"
  echo "--- installer:"; bash "$REPO/bin/fm-op-guard-install.sh" "$W"; jq -c '.hooks.PreToolUse[].hooks[].command' "$W/.claude/settings.local.json"
  echo "--- mirror before: $(git --git-dir="$GATE" rev-parse refs/heads/feat)  HEAD: $(git -C "$W" rev-parse HEAD)"
  ( cd "$W" && PATH="$LAB/shim:$PATH" env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS claude -p --model claude-haiku-5-5 \
      --permission-mode bypassPermissions --output-format stream-json --verbose \
      "Run exactly this one shell command with the Bash tool, once, and then report verbatim what happened (the output or any hook refusal message). Do not run anything else: $2" ) > "$LAB/out.json" 2>"$LAB/err.txt"; head -c 600 "$LAB/err.txt"
  jq -rR 'fromjson? | select(.type=="user") | .message.content[]? | select(.type=="tool_result") | "TOOL_RESULT: " + ((.content|tostring)[0:1500])' "$LAB/out.json"
  jq -rR 'fromjson? | select(.type=="result") | "FINAL: " + (.result // "")' "$LAB/out.json"
  echo "--- mirror after: $(git --git-dir="$GATE" rev-parse refs/heads/feat)"
}

# Scenario A: diverged mirror (pipeline fix commit only in gate), worker rebased.
setup diverged
git -C "$W" checkout -q -b tmp; echo fix > "$W/fix"; git -C "$W" add fix; git -C "$W" commit -qm "no-mistakes(review): fix"
git -C "$W" push -q no-mistakes tmp:feat; git -C "$W" checkout -q feat; git -C "$W" branch -qD tmp
git -C "$W" rebase -q main
echo "=== direct timing (diverged)"; time ( bash "$REPO/bin/fm-nm-mirror-pretool-check.sh" --command 'no-mistakes axi run --intent "ship it"' --cwd "$W" --claude; echo "rc=$?" )
claude_try "A diverged mirror, new run" 'no-mistakes axi run --intent "ship feat"'
claude_try "C diverged mirror, reattach/status" 'no-mistakes axi status'

# Scenario B: mirror holds only pre-rebase copy -> allowed.
setup rebased
git -C "$W" rebase -q main
claude_try "B rebased copy, new run" 'no-mistakes axi run --intent "ship feat"'
