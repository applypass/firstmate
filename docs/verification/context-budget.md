# Context-budget guardrail verification

Audience: maintainer verification.

This record supports the current context-ceiling guarantees in [`../context-budget.md`](../context-budget.md).
Operator behavior and active limits remain in that guide.
Task-specific chronology and delivery transcripts remain in private reports or PR evidence.

All runs below used Claude Code 2.1.220 on 2026-07-28.
Every live session run happened in a throwaway git-initialised project under the task scratchpad, never in a firstmate checkout.
The reader measurements and the block-cap reading are read-only observations over an installed harness and existing transcripts, and mutate nothing.

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

## End-to-end block proof, with enforcement driven on

This run exercised the ENFORCEMENT path, which is off in the shipped default.
It proves the enforcement path works end to end in a real session; it is not a demonstration of default behavior, and the default never reaches a blocking exit status at all.

The run predates the warning-only default: at the time the guard blocked unconditionally at the ceiling, which is exactly the behavior `FM_CONTEXT_BUDGET_ENFORCE=1` now selects.
Reproducing it today needs that variable added to the invocation below.

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
This confirms both halves of the enforcement guarantee: the ceiling blocks a real session and names the valve, and bounded blocking releases the session rather than wedging it.

The stand-down that follows a spent budget is now sticky, so a fourth and later invocation over the ceiling stays allowed and silent.
That behavior postdates this run and is covered by fixtures in `tests/fm-context-budget.test.sh` rather than by a live capture.

## The consecutive-block override cap

`docs/context-budget.md` previously repeated Claude Code's 8-consecutive-block override as bare fact.
It was unverified folklore at the time.
It is now substantiated by reading the bundled JavaScript out of the installed 2.1.220 executable:

```sh
strings -a "$(command -v claude)" | grep -o '.\{280\}CLAUDE_CODE_STOP_HOOK_BLOCK_CAP.\{280\}'
```

The relevant expression:

```js
let Kt = Rue(process.env.CLAUDE_CODE_STOP_HOOK_BLOCK_CAP, 8);
if (Kt > 0 && _o > Kt) return ... `A hook blocked the turn from ending ${_o} consecutive times - overriding and ending turn.`
```

Three facts follow, and they are what the guard's own bound is set against:

- The cap defaults to 8 and is adjustable through `CLAUDE_CODE_STOP_HOOK_BLOCK_CAP`. The same binary's user-facing text confirms it: "For Stop/SubagentStop hooks, check `stop_hook_active` in the input and return success while it's true. Set `CLAUDE_CODE_STOP_HOOK_BLOCK_CAP` to raise this limit."
- The counter it is compared against is incremented once per stop where *any* hook blocked, guarded by `blockingErrors.length > 0`. It is therefore session-wide and shared across every registered `Stop` hook, not per hook.
- A cap of `0` or less disables the override entirely.

Because the counter is shared, per-hook block budgets do not compose: several independently-budgeted blockers firing out of phase can keep consecutive stops blocked past the cap even though no single hook exceeds its own budget.
`bin/fm-context-budget.sh` answers that by standing down stickily once its budget is spent, which removes it from the shared count for the rest of the session.

## The session cannot clear itself

In the blocked run above the session answered the instruction with:

> I can't clear my own context; that's yours to do.

Clearing is a local user action with no tool surface.
Steps 1 and 2 of the valve are autonomous; step 3 requires the captain.
[`../context-budget.md`](../context-budget.md) records the resulting away-mode consequence.

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

The last-not-max compaction reset and sidechain exclusion are each covered by a fixture in `tests/fm-context-budget.test.sh`, as is the multi-block turn.

The reader has no `requestId` grouping, and deliberately so.
An earlier draft carried one, of the form `(.[-1].requestId) as $rid | [ .[] | select($rid == null or .requestId == $rid) ][-1]`.
That expression is provably equal to `.[-1]`: the last element of an array is a member of every subsequence that contains it, so filtering and then taking the last element returns that same element whether the variable was null or matched.
It was removed as dead code.

A real 81 MB session transcript confirms the field could not have carried that mechanism anyway.
Of its 14,691 assistant entries with a usage object, 14,669 have no `requestId` key at all and 22 do, and the 22 are the API-error entries.
Grouping by that field would have grouped essentially the whole transcript under `null`.

Multi-block dedupe is instead a property of taking the last entry, because each JSONL line of a multi-block turn carries that turn's own cumulative usage rather than a slice of it.
The same transcript shows the property directly: its longest run of consecutive assistant entries reporting one identical total is 13 lines at `159799`.
Summing a run like that would report thirteen times the real number; taking the last reports it exactly.

## One streaming measurement pass

The reader was originally two `jq` processes with the second slurping every parsed line into one array before filtering.
That cost landed on every single turn end, including the common case far below the advisory.

Both readers over the same 81 MB transcript, same host:

| Reader | Result | Wall | Max RSS |
| --- | --- | --- | --- |
| two passes, slurped | `444729` | 2.77 s | 299 MB |
| one streaming pass | `444729` | 0.64 s | 5.9 MB |

The measured number is identical.
The streaming pass filters and projects per line and keeps only the last emitted total, so memory is constant in transcript size rather than proportional to it.

## Native knobs remain unusable

Neither `CLAUDE_CODE_MAX_CONTEXT_TOKENS` nor `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` can enforce this ceiling; the feasibility scout recorded the decompiled reason for each.
No dependency on either is present in `bin/fm-context-budget.sh`.
