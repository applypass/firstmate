# Session handover and the helm

This is the authoritative current contract for replacing a Firstmate session whose context has grown past the point where it reasons well, and for deciding when a fresh session may take the helm from the one already holding it.
AGENTS.md section 8 carries the operating stub; the `handover` skill carries the procedure; each script's header and `--help` own exact flags and mechanics.

Two problems it closes:

- A session keeps working long past the point where its answers get worse, because nothing measures that or offers a clean replacement.
- A fresh session cannot take over when the previous one is alive but doing nothing, and it is told only that "another session holds the lock".

## The threshold

The threshold is a flat **250,000 tokens**, set in `bin/fm-session-pulse.sh` and overridable with `FM_HANDOVER_THRESHOLD` for tests and live proof.

It is deliberately not a share of the context window.
A percentage of a one-million-token window would park a session around 700,000 tokens, deep inside the degradation the threshold exists to avoid.
This is a thinking-quality line, not a capacity line: nothing overflows at 250,000, and nothing is blocked there either.

Crossing it produces one non-blocking notice per session.
Falling back below it - after a handover, or after the harness compacts - re-arms the notice for a later episode.

## Measuring the context

No turn-end hook payload carries a token count, so the number comes from the transcript the payload points at.
`bin/fm-context-measure-lib.sh` is the single owner of that measurement and of two rules every caller keeps: read `transcript_path` from the payload rather than deriving it from `$HOME`, and never write a second formula.

The total is `input_tokens + cache_creation_input_tokens + cache_read_input_tokens + output_tokens` on the last non-sidechain `assistant` entry, with three correctness rules: dedupe a multi-block turn by `requestId`, take the last entry rather than the maximum (compaction resets the running total), and exclude sidechains so a subagent's context never counts against the primary.

Per-harness support is `claude` only.
No other verified adapter's turn-end payload carries a transcript pointer, so the pulse requires `--claude` and is inert otherwise.
The activity marker below would work on any harness, but shipping half of the pulse elsewhere would create a second contract to keep in sync, so the fan-out lands with its measurement.

Every unmeasurable input - absent `jq`, a missing or unreadable transcript, a corrupt transcript, no assistant usage, empty stdin - is a silent exit 0.
The pulse runs as a `Stop` hook and must never wedge a session.

The cost is one pass over the whole transcript at every primary turn end: measured at 1.6 seconds on a real 45 MB transcript, and nothing on a crewmate turn end because the scope check runs first.
Reading only the tail would be cheaper, since the formula needs the last turn, but a tail window that cuts the only assistant entry in half degrades to unmeasurable and silently disables the notice.
That optimization is deliberately not taken here: this runs inside the machinery that supervises live work, and the current pass is the one already proven correct.

## The handover is captain-triggered

A watcher cannot respawn the interactive session in the captain's terminal, so nothing here replaces a session by itself.
Firstmate detects the threshold, prepares, verifies, and reports; the captain decides.

Past the threshold the session keeps working.
It does not stall the fleet waiting for an answer, accepting degraded reasoning in the meantime, because a stalled fleet is worse than a slower one.

## The record points, it does not assert

`data/handover.md` is durable, never a temp file, and the previous record is kept as `data/handover-prev.md`.

It is explicitly advisory: the durable records win every disagreement with it.
A session at its threshold is exactly the session whose recollections should not be trusted, so the only content it asserts is the content that exists nowhere else - the concrete next step, and what each live worker is mid-way through.
Everything else is a pointer the replacement can check.
Live fleet state is deliberately absent, because `bin/fm-session-start.sh` prints it fresh.

## The refusal

`bin/fm-handover.sh release` verifies before it frees anything, and refuses with the exact missing item.
Once the outgoing session is gone a bad handover cannot be redone, so this refusal is the most important behaviour in the feature.

It requires all of:

- a present, non-empty record carrying a `Next step:` line;
- a note for every live worker in `state/*.meta`, saying what it is mid-way through;
- a durable record behind every live thread - a backlog item for a task, a registry entry for a direct report;
- every pointer in the record resolving to a file that still exists and is non-empty.

`prepare` applies the worker half of that list too, so an unaccounted worker fails early rather than at release time.
Everything is re-checked at release even when `prepare` just passed, because a task can appear, and a record can be edited or truncated, in between.

Nothing here discards anything: it never stops a session, never touches unlanded work, and never drains the durable wake queue.

## The gap

Monitoring stops when the outgoing session ends and resumes when the replacement arms it.
That gap is accepted and made visible rather than hidden: queued wakes survive it on disk, `release` reports how many are waiting, and the replacement drains them at session start.

## Taking the helm from an idle holder

The session lock used to test only whether the holder's process was alive.
A forked or resumed background window stays alive indefinitely while doing nothing, and because watcher continuity is repaired at turn end, a holder that never ends a turn never repairs it either - so supervision can stay dead for hours behind a lock that looks healthy.

`bin/fm-helm-lib.sh` owns the replacement decision, and it requires **two independent proofs**:

- **Silence.** The newest of three mtimes: the turn-end activity marker `state/.helm-activity`, the transcript that marker names, and the session lock itself. The transcript grows during a turn, so a holder working through one long turn reads as busy rather than idle. The lock's own mtime is the baseline for a holder that has not ended a turn yet. `FM_HELM_IDLE_TAKEOVER` sets the required silence and defaults to 1800 seconds.
- **Unattended.** The holder has no controlling terminal at all, read from `ps -o tty=`.

A timer alone is never sufficient.
An attended holder keeps the helm however long it has been quiet, and any unreadable input - no marker and no lock mtime, or a terminal `ps` will not report - refuses rather than proceeding.

The marker is stamped by the `claude` pulse only, so on a primary running another harness the silence measurement falls back to the session lock's own mtime.
That is coarser but not unsafe: it can only over-estimate silence, and the unattended proof is still required, so an attended session on any harness keeps the helm.

The tradeoff in using "no controlling terminal" as the unattended proof: a session the captain is using owns a terminal device, while a session its own harness forked inherits none.
A named terminal always means refuse, even when the process-group flag suggests the session is in the background, because handing the helm away from a session someone is using is worse than one extra refusal.
[`verification/session-handover.md`](verification/session-handover.md) records the measurement behind that choice.

A takeover is reported loudly, says which session it took the helm from, states plainly that the other session was not stopped, and appends an auditable line to `state/.helm-takeover`.

When acquisition refuses instead, it prints the holder, its terminal, how long it has been quiet, why the takeover was refused, and `bin/fm-lock.sh clear --pid <holder>` - the one command that clears the helm.
`clear` refuses any pid that is not the recorded holder, and never claims to have stopped anything.
`bin/fm-lock.sh release` gives up the helm only for the session that holds it.

## What waits on the captain, and what is already answered

Two lists sat hundreds of lines into the session-start digest and were skipped, so answered questions were escalated again and standing preferences were missed.
The fix is not more text earlier.

`bin/fm-awaiting-captain.sh` prints a short block near the top of the digest: decisions held for the captain, work recorded as waiting to land, any released handover, and one line pointing at the captain's standing preferences.
It reads only local records - no network, no forge calls - so it stays cheap enough that nobody skips it.
Each list has a hard cap (`FM_AWAITING_MAX`, default 20) and says how many entries it dropped, because a silently truncated list reads as "nothing else is waiting".

Answered decisions are **searched, not preloaded**.
A preloaded list of every answered decision does not scale, is mostly irrelevant to any one session, never shrinks, and competes with the wake queue for the same first-read slot - which is how the wall of text that hid those answers got built.
So the digest carries one line - how many answers exist and the instruction to search - and `bin/fm-decided.sh search <terms>` makes the lookup at the moment of asking a single cheap command.

The search covers `data/decided.md`, the index `bin/fm-decided.sh record` appends to, plus every other decision log already in the home's `data/` directory, so existing logs are searchable with no migration.
`data/NEED_DECISION.md`-style open views are excluded: mixing unanswered items into an answered-decision search is how a pending question gets treated as settled.
Output is capped by `FM_DECIDED_MAX_LINES` (default 40) and names what it dropped.

The accepted limit: a searchable record only helps when the search happens, and plain chat cannot be intercepted to force it.
It is a habit backed by a one-line reminder in the digest and a rule in AGENTS.md section 9.
If a settled question is escalated again, that is the evidence the reminder failed and a heavier check is warranted then.

## Not covered here

- Automatic respawn of crewmates at a context ceiling. The handover machinery is deliberately shared, but nothing drives it for a worker yet.
- Cross-provider handoff when a provider's quota is exhausted. Quota is reported per provider, not per agent, so respawning on an exhausted provider yields an equally stuck worker; that is a separate concern.
- A wedged agent that never ends a turn. A turn-end mechanism cannot see one; `stuck-crewmate-recovery` owns those.

## Verification

[`verification/session-handover.md`](verification/session-handover.md) records the current evidence.
The behaviour tests are `tests/fm-session-handover.test.sh`, `tests/fm-helm-takeover.test.sh`, and the handover case in `tests/fm-session-start.test.sh`.
