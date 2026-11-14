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
