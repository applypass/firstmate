# fm-context-measure-lib adoption — live hook drives

Both Stop hooks were run as an end user runs them: fed a JSON payload on stdin,
pointing at a real transcript JSONL, in an isolated primary home
(`FM_ROOT_OVERRIDE` + secondmate marker so the primary-scope predicate matched).

## Scenario A — context-budget guard measures via the shared lib (ceiling, warn-only)
Transcript: real turn 150000, a **sidechain** subagent turn 999999, real turn 200000.

```
$ printf '%s' "$PAYLOAD" | fm-context-budget.sh --claude   # session sess-A
exit=0
{"systemMessage":"CONTEXT BUDGET CEILING REACHED - HAND OVER
This session measures 200000 tokens, over the 180000 ceiling. ...
This is a warning: the ceiling does not block by default."}

trip record:  ... stage=ceiling total=200000 ceiling=180000 advisory=150000 enforce=0 session=sess-A
notice record: stage=ceiling  compacts=0  session=sess-A
```
Measured **200000**, not 999999 — the shared lib's sidechain exclusion and
last-line rule drive the guard end to end. Notice record carries the lib's
`compacts` field.

## Scenario B — genuine-reset detection via the shared lib's compaction tally
```
# re-run same transcript -> deduped, no systemMessage (per-episode contract)
# append a NEW compaction_boundary + post-compaction turn 190000
$ ... | fm-context-budget.sh --claude
{"systemMessage":"CONTEXT BUDGET CEILING REACHED - HAND OVER
This session measures 190000 tokens, over the 180000 ceiling. ...
trip lines: before=1 after=2 (+1)
notice record compacts= now: 1
```
The compaction count returned by `fm_context_measure_transcript` (0 → 1) drove
`record_predates_a_compaction`, cleared the stale notice record and re-armed the
guard — exactly the genuine-reset the intent requires.

## Scenario C — session-pulse handover uses the same shared lib
Transcript: 100000, sidechain 888888, 260000 (threshold 250000).
```
$ ... | fm-session-pulse.sh --claude   # session pulse-sess
exit=0
{"systemMessage":"firstmate handover due: this session measures 260000 tokens,
 over the 250000 threshold ..."}
.handover-due = pulse-sess
# second run -> deduped, no output
# below-threshold transcript (90000) -> silent exit 0, .handover-due removed (re-armed)
```
Reported **260000**, excluding the sidechain 888888.

## Scenario D — single measurement owner
```
$ fm_context_measure_transcript "$TXP"
260000 0
```
The number the pulse reported (260000) equals the shared lib's total field, and
the guard's 200000/190000 came from the same call — one formula owner, two
callers.
