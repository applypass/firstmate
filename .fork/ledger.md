# Fork ledger

Every upstream (kunchenguid/firstmate) file the applypass fork modifies, and why.
`bin/fm-fork-footprint.sh` reads this file: a file listed here may change in a PR without a Fork-only block.
The list is the allowlist for the fork edits that existed when it was generated, so keep it short.
Do not add a file to dodge the check.
Prefer a new fork-only file, or a few-line `# Fork-only:` block, and list a file only when neither can work.
Format: one line per file, "- `path` - reason".
Procedure and rules: `.agents/skills/fork-upstream-resync/SKILL.md`.
Regenerate the candidate list with `git diff --name-only upstream/main...origin/main` and keep the reasons.

- `.agents/skills/agent-skill-trigger-index/SKILL.md` - Add recorded live-check frame reviewer and skill
- `.agents/skills/operational-home-layout/SKILL.md` - List validation gate files in home layout inventory
- `.agents/skills/ship-landing/SKILL.md` - Document own-PR-to-dev auto-merge in ship-landing skill; Defer gate arming before init;  release turn tells the captain
- `.github/workflows/ci.yml` - ci: pin Pi coding agent to 0.99.1
- `.gitignore` - feat(skills): add /enforce-audit skill to audit firstmate's instruction surface; docs(authority): sweep a defect class and decide it in one batched decision
- `.no-mistakes.yaml` - chore: add PR template and wire it into no-mistakes config
- `.pi/extensions/lib/fm-branch-dispatch.ts` - Resolve silent-handled keys in dispatcher trigger match and prune; Key silent-handled wakes per record;  dispatcher resolves the key
- `README.md` - feat(skills): re-layer enforce-audit skill onto upstream; feat(skills): add /enforce-audit skill to audit firstmate's instruction surface
- `bin/fm-backlog-handoff.sh` - feat(shortcut): keep a Shortcut story in sync with every backlog item (sc-6092)
- `bin/fm-branch-outcome.sh` - feat(bin): release a gated ready report in the same turn and start the run (sc-6091)
- `bin/fm-branch-prompt.sh` - Require captain outcome kind;  key silent wakes by task; feat(bin): release a gated ready report in the same turn and start the run (sc-6091)
- `bin/fm-branch-report.sh` - Quote done verb in fm-branch-report.sh for ShellCheck; Require captain outcome kind;  key silent wakes by task
- `bin/fm-brief.sh` - Refuse umbrella links, drop token export, require report helper; Gate second-mate reports, bound op read, mark story ownership
- `bin/fm-captain-hold.sh` - Key hold decisions per answer occurrence, exact replay match, tighter guard; Add fm-decide.sh: record decisions only with a Shortcut story
- `bin/fm-dod-lib.sh` - Defer gate arming before init;  release turn tells the captain; Promotion and ship spawn follow the recorded gate decision
- `bin/fm-live-lab.sh` - Link stories by Shortcut line or title;  close sync gaps
- `bin/fm-pending-reply-lib.sh` - Publish captain outcomes uncorrelated;  key silent-handled wakes per record; Fix ack escalation, captain corr rule, silent-handled timing
- `bin/fm-pr-check.sh` - Skip role refusals quietly;  auto-merge after ready line; Merge our own green PRs to dev from the ready report
- `bin/fm-pr-merge.sh` - Move stories to Done when a release is merged and deployed
- `bin/fm-promote.sh` - Promotion and ship spawn follow the recorded gate decision; Record gate decision at spawn;  drop status and release sha
- `bin/fm-secondmate-report.sh` - Mark second-mate report helper required for done/ready; Gate second-mate reports, bound op read, mark story ownership
- `bin/fm-spawn.sh` - Fix voice plugin keys and chrome session launch expectations; Close a task's chrome-devtools-axi session at teardown
- `bin/fm-task-inbox-lib.sh` - Fix ack escalation, captain corr rule, silent-handled timing; fix(secondmate): deliver every mate result to main by script (sc-6090)
- `bin/fm-tasks-axi.sh` - Link stories by Shortcut line or title;  close sync gaps; feat(shortcut): keep a Shortcut story in sync with every backlog item (sc-6092)
- `bin/fm-teardown.sh` - Close a task's chrome-devtools-axi session at teardown; feat(bin): hold the full no-mistakes run until firstmate releases it (sc-6091)
- `bin/fm-test-run.sh` - Move stories to Done when a release is merged and deployed; Add recorded live-check frame reviewer and skill
- `bin/fm-wake-lib.sh` - Resolve silent-handled keys in dispatcher trigger match and prune
- `bin/fm-watch.sh` - fix(watch): quote turn-ended kind to clear ShellCheck SC2100 (sc-6090); Key silent-handled wakes per record;  dispatcher resolves the key
- `docs/configuration.md` - Keep release next step visible and pending records honest; Move stories to Done when a release is merged and deployed
- `docs/documentation-audiences.json` - Add recorded live-check frame reviewer and skill; Classify PR template in documentation audience inventory
- `docs/fm-test-portable-shards.md` - ci: refresh serial shard weights so shard 5 stops timing out
- `docs/scripts.md` - Add recorded live-check frame reviewer and skill; Mark second-mate report helper required for done/ready
- `docs/secondmate-parent-channel.md` - Key silent-handled wakes per record;  dispatcher resolves the key; Require captain outcome kind;  key silent wakes by task
- `docs/supervision-host.md` - Document new ack and silent-handled knobs, captain kind
- `tests/fm-backend-orca.test.sh` - Fix voice plugin keys and chrome session launch expectations; Disable the voice plugin for spawned Claude workers
- `tests/fm-backlog-atomicity.test.sh` - Gate second-mate reports, bound op read, mark story ownership; Require each task's own verified Shortcut story at spawn
- `tests/fm-calm-pi-extension.test.sh` - Failing check: "Behavior portable serial 2". The only failure was tests/fm-calm-pi-extension.test.sh: "calm mode was not off by default (missing: 'CALM_E2E_OUTPUT')". This PR does not touch that test or the Pi calm code. The test's earlier serial-2 runs passed, and main's recent serial-2 failure was in a different test. Cause: a timing race in the test. The broken invariant is that a snapshot must only be checked once it holds the text being asserted. The Pi calm E2E took the default snapshot as soon as the restored transcript's last line appeared ("The deterministic tool example is complete."). But Pi can redraw the transcript a frame later, and the CI capture caught a partial frame that started at "Working...". The bash tool output it asserts was not yet on screen. The Ctrl+O block in the same test already fixed this race by also waiting for CALM_E2E_OUTPUT, so that was the one sibling site, and it is already correct. Fix: the default-snapshot block now waits for CALM_E2E_OUTPUT before its asserts, the same way the Ctrl+O block does (tests/fm-calm-pi-extension.test.sh, +4 lines). The asserts after it read the file from that final capture, which now contains the asserted text. Verification: `bash -n` and `shellcheck -x` both pass. I could not run the Pi/tmux E2E itself because pi and tmux are not installed here;  the test skips that case locally ("pi or tmux not found for Pi calm interactive E2E"). The next CI run is what will confirm the fix
- `tests/fm-claude-trust.test.sh` - I fixed the one failing test in the shard. The failure was in tests/fm-claude-trust.test.sh, in the case "the launch command did not carry a brief doorbell". Invariant: a test helper that pulls the final prompt argument out of a launch command must skip every leading `export ...; ` statement, not a fixed number of them. Cause: this PR (by the user's recorded decision) adds `export CHROME_DEVTOOLS_AXI_SESSION=<id>;  ` to every task-worker launch. Task-worker launches now begin with three export statements. The helper `claude_launch_doorbell` dropped exactly two, so `eval "set -- ..."` ran on a string that still started with an export. The last argument it returned was not the doorbell. Secondmate launches still have two exports, which is why only the task-worker case failed. Fix: `claude_launch_doorbell` now strips leading `export ...;  ` statements in a loop. This is the same pattern `claude_settings_json_arg` and `claude_launch_brief_arg` already use in tests/fm-spawn-dispatch-profile.test.sh, and those helpers passed in this shard. I made no source change;  the launch shape is the behaviour the user asked for. Sibling check: I searched tests/ for other helpers that drop a fixed number of `;  ` prefixes. The only other one is in fm-spawn-dispatch-profile, which already loops and passed in CI. Verification: tests/fm-claude-trust.test.sh passes locally, including the task-worker and both secondmate brief-doorbell cases. The first run failed early because the test isolates HOME, which breaks the local asdf node shim. Putting the real node binary on PATH fixed that;  CI is not affected
- `tests/fm-kimi-harness.test.sh` - Fix voice plugin keys and chrome session launch expectations
- `tests/fm-pending-reply.test.sh` - Fix ack escalation, captain corr rule, silent-handled timing; fix(secondmate): deliver every mate result to main by script (sc-6090)
- `tests/fm-pi-branch-extension.test.sh` - Resolve silent-handled keys in dispatcher trigger match and prune; Key silent-handled wakes per record;  dispatcher resolves the key
- `tests/fm-pr-check-security.test.sh` - Require each task's own verified Shortcut story at spawn; feat(shortcut): keep a Shortcut story in sync with every backlog item (sc-6092)
- `tests/fm-pr-merge.test.sh` - Documentation already matches Shortcut release-done behavior; Move stories to Done when a release is merged and deployed
- `tests/fm-secondmate-harness.test.sh` - Fix voice plugin keys and chrome session launch expectations; Disable the voice plugin for spawned Claude workers
- `tests/fm-spawn-dispatch-profile.test.sh` - Fix voice plugin keys and chrome session launch expectations; Disable the voice plugin for spawned Claude workers
- `tests/fm-supervision-host.test.sh` - Require captain outcome kind;  key silent wakes by task
- `tests/fm-tangle-guard.test.sh` - fix(spawn): compare worktree isolation by filesystem identity; feat(brief): re-port the sc-/type crew branch convention
- `tests/fm-task-inbox.test.sh` - Key silent-handled wakes per record;  dispatcher resolves the key; Require captain outcome kind;  key silent wakes by task
- `tests/fm-teardown.test.sh` - Close a task's chrome-devtools-axi session at teardown
- `tests/fm-test-run.test.sh` - ci: refresh serial shard weights so shard 5 stops timing out; feat: adopt sc-/type branch convention for crews
- `tests/fm-wake-queue.test.sh` - Resolve silent-handled keys in dispatcher trigger match and prune
- `tests/lib.sh` - Gate second-mate reports, bound op read, mark story ownership; Require each task's own verified Shortcut story at spawn
