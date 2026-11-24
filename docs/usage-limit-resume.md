# Usage-limit and sleep resume

A Claude usage limit stops every agent in a home at once, and nothing wakes them when it resets.
This fork detects the stop with plain scripts and resumes each endpoint after the reset.

## Flow

1. The watcher runs `bin/fm-usage-limit-tick.sh` about once a minute.
2. The tick reads the visible screen of every local endpoint in `state/*.meta`, mates and workers alike.
   A remote second mate runs the same sweep in its own home; main never reaches into it.
3. A usage-limit stop writes `state/<id>.usage-limit` once with `endpoint`, `kind` (`mate` or `worker`), `first_seen`, `reset_epoch`, `reset_source`, `attempts`, `last_attempt` and `surfaced`.
   Later ticks leave `first_seen` alone.
4. Nothing is sent before `reset_epoch` plus a 45 second grace.
5. After that the tick sends one resume steer through `bin/fm-send.sh` (a mate steer is fire-and-forget), at most 3 times, 120 seconds apart.
6. When the limit screen is gone the record clears.
7. An endpoint still stopped after the last attempt prints one `usage-limit stuck` line, which the watcher turns into a `check:` wake.
   The line holds the endpoint, first seen, reset time and the last screen lines with secrets redacted.
   `surfaced=1` keeps it to once per incident.

`bin/fm-crew-state.sh` reports an endpoint with a record as `blocked` (source `usage-limit`), never as healthy idle.

## Main's own chat

Main has no `state/*.meta`, so the sweep above would never see its session.
`bin/fm-session-start.sh` runs `bin/fm-primary-endpoint.sh record` in the locked start, and that script writes the pane it runs in to `state/.primary-endpoint` (`backend`, `target`, `harness`).
When no pane is found it removes the record instead of keeping an old one.
A secondmate home records nothing and removes any old record, so only the main home ever types into main.
Each tick then sweeps that pane with `kind=primary` and the record `state/primary.usage-limit`.
Unlike other endpoints, the screen alone never creates that record: only main's own `rate_limit` `StopFailure` hook does (below).
The screen fills in the reset time, read only from the banner and the menu, hint and key lines right under it, never from later output such as an open `/usage` panel.
Main counts as stopped for the screen only when a harness limit banner is the last transcript output directly above its composer.
A marker inside a prompt or reply is prose, not a banner: a line that opens with a prompt or reply glyph (`>`, `❯`, `⏺`, `●`) and the indented lines that continue it.
Only a real turn below the banner means main is not stopped: a prompt line that is not a local command (`/usage`, `!ls`), then a reply line or a busy spinner.
Any other output there, such as a local command's echo or an open `/usage` panel, never reaches the model, so main stays stopped.
So a relayed `usage-limit stuck` line or a reply that mentions a limit is never a stop.
The hook record already proves the stop, so a screen the banner matcher does not recognize never clears it.
That screen falls back to the quota or an assumed reset and gets one resume, with no retries and no `usage-limit stuck` line.
The record clears only when a banner an earlier sweep read is gone from the screen, when a normal `Stop` fires (main finished a turn), or `FM_UL_PRIMARY_MAX_AGE_SECS` (8 hours) after `first_seen`.
After the reset it types the resume text straight into the pane through the backend, because `bin/fm-send.sh` needs a task id.
It types only when the composer reads exactly `empty` and the pane shows no busy sign (the native busy state or the harness spinner, as `bin/fm-supervise-daemon.sh` checks); a half-typed or unreadable composer or a working main means wait, so it never types over the captain or into a running turn, and a skipped tick costs no attempt.
After a menu key it checks the composer again before it types.
Main gets no sleep or network resume; only a usage-limit stop is resumed there.
The retry limit, the menu rule and the one `usage-limit stuck` line are the same as for any endpoint.

A usage-limit stop ends main's turn through Claude's `StopFailure` event, not `Stop`.
`.claude/settings.json` registers the same `bin/fm-claude-stop-autoarm.sh` hook on both.
On a `rate_limit` `StopFailure` in the main home, the hook writes `state/primary.usage-limit` with only `endpoint`, `kind` and `first_seen`.
Claude ignores a `StopFailure` hook's exit code, so that run never arms a watcher or commits a wake, and pending signals stay on disk for the next `Stop`'s arm.
Instead the run that wrote the record waits in the background with `bin/fm-usage-limit-tick.sh --wait-primary`.
That waiter sleeps one `FM_USAGE_LIMIT_TICK_SECS` first, because the hook fires before Claude has drawn the banner, then sweeps only main's pane once per tick, with the same reset parse, grace, empty-composer check and bounded retries as the watcher's tick.
It never reads worker signals or `state/*.meta`, never wakes anyone and prints nothing.
It never takes the one `usage-limit stuck` line; a watcher tick prints it, so the line reaches a wake.
It exits once the record clears or ages out, or all attempts are spent, so main resumes even when the limit hit a turn that no watcher outlives.
The 8-hour age bound also ends a waiter whose session is gone, and a reset further out than that waits for the watcher.
A watcher already running for the fleet also sweeps main's pane; the retry spacing and the empty-composer check keep the two from typing twice.
The tick fills in the rest of the record on its first sweep and removes it on the conditions above or when no primary pane is recorded.

## Sleep and network stops

A laptop sleep kills every request in flight, and an agent can sit at an idle prompt with a connection error until someone types.
The same tick handles that stop, with `bin/fm-sleep-resume-lib.sh` as the detector.

1. A gap above 180 seconds between ticks marks a wake (`state/.sleep-wake`).
   For 10 minutes after it, every endpoint is swept as in the usage-limit flow.
2. A stop is a connection error in the last 15 screen lines (`Your computer went to sleep mid-response`, `Can't reach the API server`, `ENOTFOUND`, `ETIMEDOUT`, `ECONNRESET`, `Connection close` and similar), then an idle prompt, with no retry countdown or spinner after it.
   A line with a double quote or backtick never counts, so a command that names a marker is ignored.
3. A stop writes `state/<id>.sleep-resume` once with `endpoint`, `kind`, `cause` (`wake` or `network`), `shape`, `first_seen`, `attempts`, `last_attempt` and `surfaced`.
   A usage-limit screen always stays on the usage-limit path.
4. The tick waits 30 seconds after a wake, or 120 seconds with no wake gap, so the agent's own retry gets first go.
5. Then it sends one resume steer through `bin/fm-send.sh`, at most 3 times, 120 seconds apart.
6. The record clears when the error screen is gone.
   An endpoint still stopped after the last attempt prints one `sleep-resume stuck` line.
7. An endpoint whose process has exited is skipped: that needs a relaunch, which is a follow-up.

`bin/fm-crew-state.sh` reports a recorded connection stop as `blocked` (source `sleep-resume`).
Pmset logs are not read; the tick-gap is the wake signal.

## Reset time

The tick reads the reset from the screen first and honors a timezone shown there, for example `resets 3:10am (Asia/Kolkata)`.
Without one it asks `quota-axi --json --no-credential-refresh` for the exhausted `five_hour` or `seven_day` window.
Without that it assumes 15 minutes and re-reads the screen each tick.
A time with no date, such as `resets 2:30am`, resolves to the one moment within the window from 6 hours past (`FM_UL_PAST_SECS`) to 18 hours ahead.
So `resets 2:30am` read at 03:10 is today, read at 15:00 is tomorrow, and `resets 11:30pm` read at 00:30 is yesterday.
A banner read just after the reset therefore resumes at once instead of waiting a day.

## Menus

When the screen shows a numbered option list, the tick sends Enter only if the highlighted option waits (`Stop and wait for limit to reset`).
Any other highlight, including a credits or extra-usage option, gets Escape.
No script path ever picks an option that spends money.

## Detect by hand

```text
bin/fm-peek.sh <task> | bin/fm-usage-limit.sh --harness claude
```

It prints `usage_limit=yes|no`, `kind`, `reset`, `reset_source` and `key`, and exits 0 on a stop.

## Out of scope

Other stuck classes (login, trust dialog, unanswered steer), relaunch of an exited endpoint, a launchd waker, a spawn fail-fast fix, phone push, and a restart-until-done supervisor.
Tests: `tests/fm-usage-limit.test.sh`.
