---
name: fork-upstream-resync
description: Fork-only (applypass/firstmate). Load before changing anything in the firstmate repo itself (bin/, AGENTS.md, skills, docs, tests, workflows, config) and when resyncing with upstream kunchenguid/firstmate; it keeps the fork conflict-free to merge.
user-invocable: false
metadata:
  internal: true
---

# Fork upstream resync

applypass/firstmate is a fork of kunchenguid/firstmate.
Every edit to an upstream file is a future merge conflict, so keep the fork's footprint small.
`bin/fm-fork-footprint.sh` is the gate: the CI workflow `.github/workflows/fork-footprint.yml` enforces it on every PR.
The no-mistakes lint step also runs it, but only warns and passes when the clone has no local upstream ref.
This skill is the reminder, the check is the gate.

## Rules

1. New behaviour goes in new fork-only files (a new script, skill, test, doc, or workflow), never inside an upstream file.
2. An upstream file changes only through a short `# Fork-only:` block (`//` or `<!-- -->` comments work too): pure added lines, opened by a marker line, at most 40 lines, optionally closed by a `Fork-only end` line.
   Never delete or rewrite an upstream line.
3. Do not edit `AGENTS.md`, `README.md`, shared settings, or the doc and skill inventories unless unavoidable; hook in from a fork-only file instead.
4. A file listed in `.fork/ledger.md` may change freely, but the check reads the ledger from the PR's base branch, so a PR cannot allowlist its own edits.
   A new entry needs its own reviewed PR and applies once merged; the footprint summary names any working-tree entries it ignored.
   List a file only when neither a new file nor a block can work, and give the reason.
5. Every PR body that changes the repo pastes the "Fork footprint vs upstream main" section printed by `bin/fm-fork-footprint.sh`.

Check before pushing: `bin/fm-fork-footprint.sh` (add `--fetch` to refresh `upstream/main`).
It exits 1 and names each file and line outside a block.

## Resync procedure

1. `git fetch upstream && git fetch origin`, then `git checkout -b chore/reconcile-upstream-<date> origin/main`.
2. `git merge upstream/main`; the check compares each file with the upstream it merged, so lines taken from upstream never count.
   Resolve each conflict by keeping upstream's text and re-applying the fork's `# Fork-only:` block beside it.
   Move a conflicting fork change into a new fork-only file or a block when it is not one already.
3. Update `.fork/ledger.md`: drop files the fork no longer changes.
4. Run `bin/fm-lint.sh`, `bin/fm-fork-footprint.sh`, and the tests for the touched code.
5. Open a PR to `main` with the footprint section in its body.

Ledger: `.fork/ledger.md`.
Check: `bin/fm-fork-footprint.sh` (header owns the exact rules); tests: `tests/fm-fork-footprint.test.sh`.
