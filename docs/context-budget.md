# Primary context-budget guardrail

This is the authoritative current contract for the context ceiling referenced from AGENTS.md section 8.
The predicate lives in `bin/fm-context-budget.sh`.
Primary scope lives in `bin/fm-primary-scope-lib.sh`, shared with the turn-end supervision guard in [`turnend-guard.md`](turnend-guard.md) and the native session-start nudge in [`sessionstart-nudge.md`](sessionstart-nudge.md).

This guard is a sibling of the turn-end supervision guard, not part of it.
Both run on the same `Stop` event and both scope through the same shared predicate, but they own different contracts: the supervision guard owns "no turn ends blind", and this one owns "no session runs past the context ceiling".
Do not infer one guard's thresholds, loop safety, or degradation behavior from the other.

## What this is for

Firstmate sessions run toward roughly 800,000 tokens before Claude's own auto-compaction fires.
This guard fires far earlier, at an absolute 180,000 tokens, so the balloon never forms.

That makes it a deliberate cost and reasoning-quality policy, not overflow prevention.
Nothing crashes at 180,000 tokens on a 1M-context session.
What degrades is answer quality and token spend, and both degrade long before the harness would intervene on its own.

The ceiling is an absolute token count and never a fraction of a detected window.
The window is not inferable from the transcript: a 1M session records `message.model` as `claude-opus-5` with the `[1m]` marker stripped, so a proportional ceiling has nothing trustworthy to be proportional to.

## Current invariant

At every primary turn end, the guard measures the live session's context.
Below the advisory point it is completely silent.
Between the advisory point and the ceiling it prints one non-blocking notice per episode.
At or above the ceiling it blocks the turn end and requires the handoff-and-clear valve, bounded so a session can always end.

## Measurement

No hook payload on any harness carries a token, usage, or context field, so the number comes from the transcript.

`transcript_path` is read from the hook payload and never derived from `$HOME`.
A non-default Claude config directory puts the transcript somewhere `$HOME` cannot predict; [`verification/context-budget.md`](verification/context-budget.md) records a live path under `~/.claude-work` that proves this.

The context total is the sum of `input_tokens`, `cache_creation_input_tokens`, `cache_read_input_tokens`, and `output_tokens` on the last non-sidechain `type=="assistant"` entry.
That formula reproduces Claude Code's own accounting exactly rather than approximating it.

Three correctness rules the measurement keeps:

- **Dedupe by `requestId`.** A multi-block assistant turn writes several JSONL lines for one turn. Summing them would report a multiple of the real total and fire the guard far too early.
- **Last, never max.** Compaction resets the running total. A `max` implementation would latch the pre-compaction peak and disable the guard permanently after the first compaction.
- **Exclude sidechains.** `isSidechain == true` marks subagent turns, which must never inflate the primary's measurement.

Malformed transcript lines are dropped rather than aborting the pass, so a half-written final line degrades to the last line that parsed.

## Thresholds

The ceiling is the enforce point and the only policy number.
The advisory point is derived as `ceiling - headroom`, so there is never a second threshold to keep in sync.

| Stage | Default | Behavior |
| --- | --- | --- |
| Advisory | 150,000 (`ceiling - headroom`) | One visible non-blocking notice per episode. Prefer cheap actions, avoid large reads. |
| Ceiling | 180,000 | Block the turn end and require the valve. |

`FM_CONTEXT_BUDGET_CEILING` overrides the ceiling and defaults to 180000.
`FM_CONTEXT_BUDGET_HEADROOM` overrides the headroom and defaults to 30000, about two worst-case turns on top of the valve's own cost.
`FM_CONTEXT_BUDGET_BLOCK_BUDGET` overrides the consecutive-block bound and defaults to 3, safely below Claude Code's own 8-consecutive-block override.
A non-numeric or zero value falls back to the default rather than disabling the guard.

The advisory banner prints once per episode and re-arms once the measurement drops back below the advisory point, the same shape `bin/fm-guard.sh` uses.

## The valve

There is exactly one valve: write a handoff and clear.

1. Run `/stow` to write durable knowledge, decisions, and unfinished work to disk.
2. Write a handoff note naming what the session was doing and the exact next step.
3. Clear the context and resume from the stowed record.

The valve is built on `/stow`, which is tracked in `.agents/skills/stow/` and already exists to leave a session safe to reset.
It is deliberately not built on `/handoff`, which is a personal untracked skill absent on other machines.
Where `/handoff` happens to be installed it is an optional local enhancement, never a requirement.

The guard instructs and nothing more.
It never types into a pane, never injects `/compact`, `/clear`, or any other command, and never spawns a replacement agent.
Compacting in place and spawning a fresh agent are not offered as alternatives; there is one deterministic valve.

## Known limitation: the session cannot clear itself

Steps 1 and 2 are fully autonomous.
Step 3 is not: clearing the context is a local user action with no tool surface, so the session can prepare the handoff but cannot complete the reset itself.
A live session confirmed this directly, replying "I can't clear my own context; that's yours to do" ([`verification/context-budget.md`](verification/context-budget.md)).

With the captain present this closes normally: the block surfaces the instruction, the session stows and writes the note, and the captain clears.

While away mode is active there is no captain to clear, so the valve cannot close.
The guard still blocks, still gets the durable knowledge written to disk by steps 1 and 2, and then degrades to a visible allow once the block budget is spent.
The session continues over the ceiling until the captain returns.
This is a real gap, and it is preferred over the alternative: injecting keystrokes into a live session was ruled out deliberately, and a guard that wedges an unattended session would be worse than one that warns and lets it run.

## Never wedge a session

Every measurement failure is a silent exit 0: absent `jq`, missing or unreadable `transcript_path`, a missing, empty, unreadable, or corrupt transcript, a transcript with no assistant usage, and empty or malformed stdin.
A bare or unsupported-harness invocation is also inert rather than a blocking usage error.

Blocking is bounded.
After `FM_CONTEXT_BUDGET_BLOCK_BUDGET` consecutive blocks in one session the guard allows the turn end with a visible `systemMessage` that still names the valve.
Any allow resets the budget, so a later balloon in the same session gets the full budget again.

## Scope

The guard binds primary firstmate sessions: the main home and every secondmate's own home.
A secondmate runs its own primary session and is measured and enforced exactly like the main primary, whether its home is a treehouse-leased linked worktree or a plain clone.

Crew subagent turns are inert, by two independent mechanisms:

- The guard is registered on `Stop`, which fires for the primary turn only. A subagent's completion fires `SubagentStop`, which the guard is not registered on.
- Claude Code 2.1.220 writes subagent turns to a separate `<session-id>/subagents/agent-<id>.jsonl` file. The `transcript_path` in the payload points at the parent transcript, which contains none of them, and the `isSidechain` filter excludes them regardless of layout.

Crewmate and scout task worktrees are outside scope through the shared primary predicate, because their git dir differs from their git common dir and they never carry the secondmate marker.

## Per-harness support

This slice supports claude only.
Nothing here claims universal coverage.

| Harness | Status | Reason |
| --- | --- | --- |
| claude | **Supported** | `transcript_path` on every hook payload, measurement cross-validated against the harness's own accounting. |
| codex | Later | Forwards a full `Stop` payload, but whether it carries a transcript pointer is unverified. Needs its own probe. |
| opencode | Later | Plugin runtime with an SDK session object; the usage route is unverified. Needs its own probe. |
| pi | Later | Sessions persist on disk, so a transcript equivalent exists. Needs its own probe. |
| grok | **Not deliverable** | Project-hook stdout does not reach model context, so even a correct measurement cannot be delivered as an instruction. |
| kimi | **Not supported** | The `Stop` payload carries no transcript pointer at all, so the session cannot self-measure. A turn-count proxy spans a 119x range and would not defend the number. |

Each remaining harness needs the harness installed and its own probe, and lands as its own change.

## Registration

Claude registers three `Stop` hooks in `.claude/settings.json`, all anchored through `CLAUDE_PROJECT_DIR`: `bin/fm-turnend-guard.sh --claude`, `bin/fm-context-budget.sh --claude`, then `bin/fm-claude-stop-autoarm.sh`.
Stacking a third `Stop` hook is the established pattern, not a new mechanism.

The guard is deliberately not folded into `bin/fm-turnend-guard.sh`, which owns exactly one predicate, and it deliberately does not use `PreToolUse`, which would run many times per turn for no extra safety and cannot act at a safe boundary.

Neither native knob can do this job.
`CLAUDE_CODE_MAX_CONTEXT_TOKENS` is ignored on a 1M model, which short-circuits to its own limit before the variable is read, and is honoured only when `DISABLE_COMPACT` removes the mechanism that would respect it.
`CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` is an internal test knob that did not trigger compaction when set far below the live baseline.
Firstmate measures and enforces this itself.

## Regression coverage

`tests/fm-context-budget.test.sh` covers the three measurement correctness rules, the derived advisory and its per-episode dedup and re-arm, the absolute 180,000 default, the full degradation matrix, main and secondmate primary scope, crewmate and secondmate-child worktree exclusion, the bounded block budget and its per-session keying and reset, claude-only mode gating, the tracked `Stop` registration, and the one-owner and no-injection boundaries.
[`verification/context-budget.md`](verification/context-budget.md) records the live measurements, the end-to-end block proof, and the secondmate and subagent characterization.
