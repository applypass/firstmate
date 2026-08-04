---
name: handover
description: Hand this firstmate session over to a fresh one when its context passes the thinking-quality threshold. Use when the captain invokes /handover or asks to hand over, when a turn end reports that a handover is due, and when a session start surfaces a handover left by the previous session. Prepares a durable advisory record of the next step and what each worker is mid-way through, verifies every open thread is backed by a durable record, refuses to give up the helm until it is, then releases the helm so a replacement can take it and pick the work up from disk.
user-invocable: true
metadata:
  internal: true
---

# handover

A session past 250,000 tokens reasons worse than a fresh one, so the captain replaces it.
This skill covers both sides: the outgoing session that prepares and releases, and the replacement that picks the work up.

`bin/fm-handover.sh --help` owns the exact commands and their mechanics.
`docs/session-handover.md` owns the thresholds, the record format, and the tradeoffs.

## When a turn end says a handover is due

Nothing is blocked and nothing is urgent.
Keep working through whatever is in flight, and at the next natural reply tell the captain in one line that a handover is due and that you have one ready.
Do not stall the fleet waiting for the captain, and do not report it twice.

## Preparing, as the outgoing session

1. Write only what exists nowhere else.
   The record is advisory: durable records win every disagreement with it, so anything already on disk stays a pointer.
   What is not on disk anywhere is the concrete next step, and what each live worker is mid-way through.
2. Run `bin/fm-handover.sh prepare --next "<the one concrete next step>" --worker <id>="<what it is mid-way through>"` with one `--worker` for every live worker, including idle direct reports.
   It refuses while any live worker is unaccounted for.
   Add `--record <path>="<why>"` for any further record the replacement genuinely needs; the standing records are added for you.
3. Read what `prepare` reports back.
   If it refuses, fix the named item - usually a missing note, or a task with no backlog item - and prepare again.

Never invent a fact for the record.
A session at its threshold is exactly the session whose recollection should not be trusted: this fleet has already lost a day to a worker that wrote itself a note claiming an approval the captain never gave, then acted on it later.
Anything you cannot point at, leave out.

## Releasing, on the captain's word

`bin/fm-handover.sh release` verifies everything again and then frees the helm.
If it refuses, nothing was released and nothing was lost - fix exactly what it names and run it again.
Never work around a refusal: once this session is gone, a bad handover cannot be redone.

After a successful release this session is read-only.
Do not spawn, steer, merge, or repair fleet state from here.
Tell the captain in one line that the handover is ready and a fresh session can start.

Monitoring stops when this session ends and resumes when the replacement arms it.
That gap is expected and safe: queued notifications survive it on disk and the replacement drains them at session start.

## Picking it up, as the replacement

Session start prints the record in full, so do not re-read it.

1. Treat it as advisory.
   Check each line against the records it names and against the fleet digest; those win.
2. Do not re-derive anything a durable record already answers.
   Read the records the handover points at, and search `bin/fm-decided.sh search <terms>` before escalating any question - it may already be answered.
3. Run `bin/fm-handover.sh consume` to close it out.
   It lists the records you were expected to read.
4. Report to the captain in one line: what is live, what the next step is, and which records you consulted.

## Taking the helm from an idle holder

A fresh session takes the helm automatically only when the previous holder is provably unattended and measurably silent; `bin/fm-lock.sh` reports it loudly when it does.
When it refuses instead, it names what holds the helm and the one command that clears it.
Relay that to the captain as a plain choice - the old session is still open and someone may be using it - and never clear the helm from a session the captain has not agreed to give up.
