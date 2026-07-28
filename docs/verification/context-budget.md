# Context-budget guardrail verification

Audience: maintainer verification.

This record supports the current context-ceiling guarantees in [`../context-budget.md`](../context-budget.md).
Operator behavior and active limits remain in that guide.
Task-specific chronology and delivery transcripts remain in private reports or PR evidence.

All runs below used Claude Code 2.1.220 on 2026-07-28, in a throwaway git-initialised project under the task scratchpad, never in a firstmate checkout.

## Payload carries no token data

A `Stop` payload recorded from a live session carries these keys and no token, usage, or context field:

```
background_tasks,cwd,effort,hook_event_name,last_assistant_message,permission_mode,
prompt_id,session_crons,session_id,stop_hook_active,transcript_path
```

Measurement must therefore come from the transcript the payload points at.

## transcript_path is not derivable from $HOME

The same payload resolved `transcript_path` under this shape, with the home prefix elided here:

```
~/.claude-work/projects/<slugified-project-path>/<session-uuid>.jsonl
```

The config directory is `~/.claude-work`, not `~/.claude`.
A guard that reconstructed the path from `$HOME` would have missed the transcript entirely and degraded to silence on every turn.
`bin/fm-context-budget.sh` reads the path from the payload only.

## Live measurement matches the transcript

A baseline session measured through the shipped reader:

```sh
FM_CONTEXT_BUDGET_CEILING=900000 bash bin/fm-context-budget.sh --claude < last-stop-payload.json
```

Result: exit 0, silent.
Independently summing the last non-sidechain assistant entry's four usage fields over the same transcript returned `30454`, the same number the guard computed.

## End-to-end block proof

The guard was registered as a real `Stop` hook in the scratch project's `.claude/settings.json`, then driven with the ceiling set below the session's own baseline:

```sh
FM_CONTEXT_BUDGET_CEILING=20000 FM_CONTEXT_BUDGET_BLOCK_BUDGET=2 \
  claude -p 'Reply with exactly: LIVEPROOF3_OK' </dev/null
```

Observed: the hook ran three times in the single run and recorded exit status 2, 2, then 0.
The two blocking invocations emitted:

```
●  CONTEXT BUDGET CEILING REACHED - HAND OFF AND CLEAR
●  This session measures 32633 tokens, over the 20000 ceiling.
●  Take the valve now, before any other work:
●    1. Run /stow to write durable knowledge, decisions, and unfinished work to disk.
●    2. Write a handoff note naming what you were doing and the exact next step.
●    3. Clear the context and resume from the stowed record.
```

The third invocation allowed the turn end once the block budget was spent.
The `claude` process exited 0.
This confirms both halves of the guarantee: the ceiling blocks a real session and names the valve, and bounded blocking releases the session rather than wedging it.

## The session cannot clear itself

In the blocked run above the session answered the instruction with:

> I can't clear my own context; that's yours to do.

Clearing is a local user action with no tool surface.
Steps 1 and 2 of the valve are autonomous; step 3 requires the captain.
[`../context-budget.md`](../context-budget.md) records the resulting away-mode limitation.

That same run also reported `/stow` missing, because the bare scratch project carried no skills directory.
`/stow` is tracked at `.agents/skills/stow/` with `user-invocable: true`, and `.claude/skills` symlinks to it, so it resolves in every real firstmate home and secondmate home.
The lab was re-provisioned with the tracked skills tree to confirm this, and the absence was a property of the bare lab, not of the valve.

## Secondmate primary sessions are bound

A genuine linked worktree was created and marked as a secondmate home:

```
git-dir       : .../ctxlab/.git/worktrees/ctxlab-sm
git-common-dir: .../ctxlab/.git
```

The two differ, so this has the exact shape of a treehouse-leased secondmate home and would be exempt under the linked-worktree test alone.

Controlled pair, same worktree, same transcript, same ceiling, marker as the only variable:

| `.fm-secondmate-home` | Guard exit | Banner |
| --- | --- | --- |
| present | 2, then 0 past the budget | `CONTEXT BUDGET CEILING REACHED` |
| absent | 0 | none |

A secondmate's own primary session is measured and enforced exactly like the main primary.
The same worktree without the marker has the shape of a crewmate or scout task worktree and stays inert whatever its context size.

## Subagent context is separate and never counted

A live session was driven to spawn one general-purpose subagent through the `Task` tool.

`SubagentStop` fired once; the primary `Stop` hook fired once.
Both payloads carried the same `transcript_path`, pointing at the parent transcript.

Entry census of that parent transcript:

```json
{ "total": 14, "assistant_total": 3, "assistant_sidechain": 0, "assistant_mainchain": 3 }
```

The subagent's turns are not in the parent transcript at all.
Claude Code 2.1.220 writes them to a separate file:

```
<project>/<session-id>/subagents/agent-<id>.jsonl
```

Census of that file: 7 entries, all 7 carrying `isSidechain: true`, last assistant total `24461`.

Meanwhile the guard measured the primary at `33217`.
The subagent's 24,461 tokens never reached the primary's number.

The guardrail is therefore inert for crew subagent turns by two independent mechanisms: the guard is registered on `Stop`, which a subagent's completion does not fire, and the payload's `transcript_path` points at a parent transcript that contains no subagent entries.
The `isSidechain != true` filter remains in the reader as defence in depth, and is verified against synthetic fixtures in `tests/fm-context-budget.test.sh` because the current on-disk layout no longer produces inline sidechain entries to exercise it.

This partially corrects the feasibility scout, which expected subagent turns to appear inline in the parent transcript marked `isSidechain: true`.

## Correctness rules

Summing every assistant usage object in the subagent run's parent transcript returned `99407` against a correct measurement of `33217`.
That is the concrete cost of a naive implementation that adds turns instead of taking the last one.

The requestId dedupe, the last-not-max compaction reset, and sidechain exclusion are each covered by a fixture in `tests/fm-context-budget.test.sh`.

## Native knobs remain unusable

Neither `CLAUDE_CODE_MAX_CONTEXT_TOKENS` nor `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` can enforce this ceiling; the feasibility scout recorded the decompiled reason for each.
No dependency on either is present in `bin/fm-context-budget.sh`.
