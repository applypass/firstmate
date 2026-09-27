---
name: enforce-audit
description: >-
  Audit firstmate's always-loaded instruction surface - data/captain.md, AGENTS.md, every
  .agents/skills/*/SKILL.md, and docs/*.md - and produce a severity-ordered classified
  inventory: which rules are worth keeping at all, and for the rest, whether each belongs in
  a regression test, a hook, a CI check, an on-demand skill, or stays as judgment-call
  instruction text. Use when the captain invokes /enforce-audit, or when a session-start
  STARTUP_MEMORY_BUDGET diagnostic suggests it because the always-loaded surface is nearing
  its budget.
user-invocable: true
metadata:
  internal: true
---

# enforce-audit

Firstmate's always-loaded instruction surface accumulates rules over time.
Some are dead, some are no-ops that no longer change any agent's behavior, some are settled
lessons that carry no live decision, and many of the rest are enforced only as prose when a
mechanical check would catch the same mistake for free and never cost another worker's context
budget again.
This skill produces a recommendation report on that surface.
It never edits an instruction file and never builds any enforcement itself; every accepted
recommendation becomes its own separate, grilled ship task later.

## Dispatch, not inline execution

Invoking `/enforce-audit` writes a scout brief and dispatches a scout worker; it does not run the
audit in the main session.
Follow the ordinary section 7 scout dispatch contract: this task's project is firstmate itself, so
scaffold with `bin/fm-brief.sh <task-id> firstmate --scout`, fill `## Captain's intent` with the
captain's actual ask (or, for a nudge-triggered run, the framework's own purpose stated plainly),
and fill `## Firstmate spec` with the framework below.
Then dispatch and supervise the scout exactly as any other scout: `bin/fm-spawn.sh`, steer through
its inbox, and treat its report as the Done artifact.

The scout reads `data/captain.md`, `AGENTS.md`, every `.agents/skills/*/SKILL.md`, and `docs/*.md`.
It edits no instruction file and builds no enforcement; its only deliverable is the report.

## Framework the scout brief must specify

**Step 0 - baseline what already enforces things.**
Before proposing anything, inventory what already mechanizes a rule: `bin/fm-*-check.sh` scripts,
the hooks wired in `.claude/settings.json`, `.github/workflows/`, and script preconditions.
Nothing already-mechanized gets re-proposed.
An already-wired-but-broken gate is itself a finding, not a reason to skip that rule.

**Phase 1 - is the rule worth keeping at all?**
Drop, don't relocate:
- No-ops: instructions that change no agent's behavior.
- Dead or obsolete rules: the system they governed no longer exists or works the way the rule assumes.
- Settled lessons that carry no live decision and are better expressed as a regression test than as a
  standing instruction every session pays to read.

**Phase 2 - for what survives, where does it belong?**
Organize by a mechanical-vs-judgment spine, buckets nested under it:

- **Mechanical** - a discrete interceptable action or a repo-observable fact exists:
  - `HOOK` - a firstmate-home PreToolUse/Stop hook wired in `.claude/settings.json`, backed by a
    `bin/fm-*-check.sh`.
  - `CI` - a `.github/workflows` check.
  - `DELETE` - remove the instruction text and replace it with a regression test in the specific
    code it protects.
  Name the concrete mechanism and where it wires for every mechanical recommendation.
- **Situational** - `ON_DEMAND`: a skill loaded only on its own named trigger, not always-loaded.
- **Judgment** - `KEEP`: irreducible judgment calls that no check could substitute for - honesty,
  pushback, "is the problem real", escalation calls, cross-file consistency, "matches the
  surrounding style."

Default to building the check over writing the rule.

For each candidate, record:
- rule (one line)
- source (file + section, or line when pinnable)
- class (drop / HOOK / CI / DELETE+test / ON_DEMAND / KEEP)
- concrete mechanism (the specific hook, check, or test - not just the bucket name)
- blast radius (internal-only vs teammate-facing)
- effort (S/M/L)
- failure mode / risk if the recommendation is wrong

Flag every teammate-facing proposal - a product-repo CI check that would gate other humans' PRs -
as a decision the report surfaces rather than assumes; do not recommend it as a settled action.

## Borrowed from `retro`

This framework reuses several ideas from the general-purpose `retro` skill, which finds and
recommends environment improvements but does not know firstmate's own architecture:

- The mechanical-vs-judgment split as the organizing spine.
- "Default to the check over the rule."
- Reading the repo's own existing checks first, so an unwired or silently broken gate is the
  finding, not a reinvention.
- No-op detection: instructions that don't change behavior.
- The implementation-vs-review placement principle: mechanical gates belong in hooks, CI, or the
  no-mistakes review pipeline, not in the always-loaded worker brief every worker pays for -
  because the implementation agent carries the most context pressure, and the review agent the
  least.
- "AGENTS.md lines are navigation pointers, used sparingly."

This skill does not copy `retro`'s generic file model (`CODING_STANDARDS.md`) or its session-log-driven
trigger, because firstmate's surface is `AGENTS.md` plus `.agents/skills/*/SKILL.md` plus `docs/*.md`,
not a generic project's standards file, and this audit runs on-demand against that surface rather than
against one session's transcript.
Leave `retro` itself unchanged; do not edit it as part of this work.

## Output and gating

The report is a severity-ordered classified inventory with concrete recommendations only.
It never edits `data/captain.md`, `AGENTS.md`, a skill file, or a doc, and it never wires a hook, a CI
check, or a test - those are follow-up ship tasks, each grilled and scoped on its own.
Before the report is treated as done, the scout follows `captain-hold-lifecycle` and holds any
genuine decision the audit surfaces (most often: a teammate-facing proposal, or a judgment call
about whether a "settled lesson" still carries a live decision) so the completion gate is not
bypassed by a large but decision-free finding list.

## Out of scope

State these as out of scope rather than building them:
- Implementing any enforcement the audit recommends.
- A monthly or otherwise scheduled auto-run; this version is on-demand only.
- Editing `data/captain.md` content.
- Any change to the `retro` skill.

## Cadence: on-demand, nudged from the existing startup-memory-budget signal

No cron, daemon, or new polling.
The nudge reuses the session-start `STARTUP_MEMORY_BUDGET` diagnostic that `bin/fm-bootstrap.sh`
already emits and that `bootstrap-diagnostics` already routes; when that path fires, it suggests
running `/enforce-audit` as one line of guidance.
This is the same budget signal, reused - not a second budget check.
