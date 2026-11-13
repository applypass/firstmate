# Step 1 cold-start measurement: workers drop unused tool definitions

Real `claude -p` cold starts, Claude Code 2.1.323, model sonnet, empty strict MCP
config (the worker default), same neutral temp dir, prompt "Reply with exactly: OK".
Total input = input + cache_creation + cache_read tokens of the single turn.

| launch flags                                   | run 1  | run 2  |
|------------------------------------------------|--------|--------|
| full tool set (scout before this change)       | 33,352 | 33,337 |
| base: drop 4 tools (ship before this change)   | 29,682 | 29,670 |
| new: drop 6 tools (ship + scout after change)  | 28,366 | 28,358 |

Saving per cold start:
- ship / final-run worker: 29,670 -> 28,358 = 1,312 tokens (ReportFindings + ShareOnboardingGuide)
- scout worker:            33,337 -> 28,358 = 4,979 tokens (all six tools)

Tool lists reported by the model (run 1): the new launch lists none of Artifact,
Workflow, ScheduleWakeup, AskUserQuestion, ReportFindings, ShareOnboardingGuide;
the full launch lists ReportFindings, ScheduleWakeup, ShareOnboardingGuide, Workflow.
