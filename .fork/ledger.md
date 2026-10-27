# Fork ledger

Every upstream (kunchenguid/firstmate) file the applypass fork modifies, and why.
`bin/fm-fork-footprint.sh` reads this file: a file listed here may change in a PR without a Fork-only block.
The list is the allowlist for the fork edits that existed when it was generated, so keep it short.
The check reads this file from the PR's base branch, so a new entry needs its own reviewed PR and applies once merged.
Prefer a new fork-only file, or a few-line `# Fork-only:` block, and list a file only when neither can work.
Format: one line per file, "- `path` - reason".
Procedure and rules: `.agents/skills/fork-upstream-resync/SKILL.md`.
Regenerate the candidate list with `git diff --name-only upstream/main...origin/main` and keep the reasons.

- `.agents/skills/agent-skill-trigger-index/SKILL.md` - indexes the fork-only live-check frame reviewer skill
- `.agents/skills/operational-home-layout/SKILL.md` - lists the fork validation gate files in the home layout
- `.agents/skills/ship-landing/SKILL.md` - documents own-PR-to-dev auto-merge and the deferred gate release
- `.github/workflows/ci.yml` - pins the Pi coding agent version
- `.gitignore` - ignores enforce-audit and authority sweep outputs
- `.no-mistakes.yaml` - wires the PR template and the fork footprint check into no-mistakes
- `.pi/extensions/lib/fm-branch-dispatch.ts` - resolves silent-handled wake keys in dispatch
- `README.md` - documents the enforce-audit skill
- `bin/fm-backlog-handoff.sh` - keeps a Shortcut story in sync with each backlog item
- `bin/fm-branch-outcome.sh` - releases a gated ready report in the same turn
- `bin/fm-branch-prompt.sh` - requires a captain outcome kind and keys silent wakes by task
- `bin/fm-branch-report.sh` - requires a captain outcome kind and keys silent wakes by task
- `bin/fm-brief.sh` - requires the report helper and marks Shortcut story ownership
- `bin/fm-captain-hold.sh` - keys hold decisions per answer and records them with a Shortcut story
- `bin/fm-dod-lib.sh` - defers gate arming and follows the recorded gate decision
- `bin/fm-live-lab.sh` - links Shortcut stories by line or title
- `bin/fm-pending-reply-lib.sh` - publishes captain outcomes and keys silent-handled wakes per record
- `bin/fm-pr-check.sh` - auto-merges own green PRs to dev from the ready report
- `bin/fm-pr-merge.sh` - moves Shortcut stories to Done on release
- `bin/fm-promote.sh` - records the gate decision at spawn and follows it on promotion
- `bin/fm-secondmate-report.sh` - gates second-mate done and ready reports
- `bin/fm-spawn.sh` - disables the voice plugin and manages chrome-devtools-axi sessions
- `bin/fm-task-inbox-lib.sh` - delivers every mate result to main by script
- `bin/fm-tasks-axi.sh` - keeps Shortcut stories in sync with backlog items
- `bin/fm-teardown.sh` - closes chrome-devtools-axi sessions and holds the no-mistakes run
- `bin/fm-test-run.sh` - runs the live-check frame reviewer and release Done moves; lists the fork-only tests in the serial weight hints
- `bin/fm-wake-lib.sh` - resolves silent-handled wake keys
- `bin/fm-watch.sh` - keys silent-handled wakes per record
- `docs/configuration.md` - documents release next steps and Shortcut Done moves
- `docs/documentation-audiences.json` - classifies the fork-only docs and skills
- `docs/scripts.md` - documents the fork-only scripts
- `docs/secondmate-parent-channel.md` - documents captain outcome kinds and silent-handled wake keys
- `docs/supervision-host.md` - documents the ack and silent-handled knobs
- `tests/fm-backend-orca.test.sh` - covers the voice plugin and chrome session launch
- `tests/fm-backlog-atomicity.test.sh` - covers the per-task verified Shortcut story
- `tests/fm-calm-pi-extension.test.sh` - waits for the full Pi calm snapshot before asserting
- `tests/fm-kimi-harness.test.sh` - covers the voice plugin and chrome session launch
- `tests/fm-pending-reply.test.sh` - covers ack escalation and mate result delivery
- `tests/fm-pi-branch-extension.test.sh` - covers silent-handled wake keys in dispatch
- `tests/fm-pr-check-security.test.sh` - covers the per-task verified Shortcut story
- `tests/fm-pr-merge.test.sh` - covers Shortcut Done moves on release
- `tests/fm-secondmate-harness.test.sh` - covers the voice plugin and chrome session launch
- `tests/fm-spawn-dispatch-profile.test.sh` - covers the voice plugin and chrome session launch
- `tests/fm-supervision-host.test.sh` - covers captain outcome kinds
- `tests/fm-tangle-guard.test.sh` - covers worktree identity and the sc- branch convention
- `tests/fm-task-inbox.test.sh` - covers silent-handled wake keys and captain outcome kinds
- `tests/fm-teardown.test.sh` - covers chrome-devtools-axi session teardown
- `tests/fm-wake-queue.test.sh` - covers silent-handled wake key pruning
- `tests/lib.sh` - adds helpers for Shortcut story and second-mate report tests
