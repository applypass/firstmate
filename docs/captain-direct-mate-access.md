# Captain access to second mates (applypass fork)

Three pieces let the captain talk to a second mate without going through the main firstmate.

## Typing into a second mate's pane

A second mate answers its parent, and nobody reads its chat.
When the captain types into the mate's own pane, `bin/fm-captain-direct.sh` (a UserPromptSubmit hook) does two things.
It appends one line to the mate's parent channel, the file `bin/fm-secondmate-report.sh` writes:

```text
captain-direct [at=<epoch>]: <his words, one line, at most 200 characters>
```

It also tells the mate to answer in the pane, in plain captain style.
The main firstmate sees the line at its next wake drain, not at the next reconcile.
The classifier surfaces the unknown `captain-direct` verb as an event of its own.
It is never an open decision and never the answer to a marked request, because it has no `corr=` token.
Outcomes (ready, needs-decision, done, blocked) still go through `bin/fm-secondmate-report.sh`.

Firstmate's own traffic is not the captain: the steering doorbell, a `[fm-from-firstmate]` message, operational input, and harness task notifications write nothing.

## Read-only side session

`bin/fm-ask.sh <home|mate-id|main>` opens a Claude session on any home.
It never runs session start and never takes the home's lock.
It runs in an empty scratch directory with only the user's settings, so the home's `CLAUDE.md` and hooks do not load.
The session answers from the home's records, reports, and status.
A PreToolUse hook (`bin/fm-ask-pretool-check.sh`, decision in `bin/fm-ask-command-policy.mjs`) allows only read tools and a list of read-only commands.
Every other command is refused, including send, spawn, merge, drain, hold, decide, teardown, and backlog writes.
The check stops safely: a payload it cannot read or parse is refused.

For a second mate home there is one exception.
An order is queued to the owning mate's steering inbox through `bin/fm-ask-order.sh`, which calls `bin/fm-send.sh`.
The target is fixed by the launcher, so the session cannot redirect it.
The session replies "queued" and says what the mate's latest status shows it doing.

Routing order for a question about a second mate's work: the owning mate, then a read-only session on that mate's home, then main last.

## Reply first

`bin/fm-reply-first.sh` counts tool calls after a message that expects an answer.
After 3 calls without a reply, the next call is refused once with "answer now with what you have, hand the rest off".
A reply is a `bin/fm-secondmate-report.sh` call, or assistant text of 200 characters or more.
`FM_REPLY_FIRST_LIMIT` and `FM_REPLY_FIRST_MIN_CHARS` tune it.
The latency report of 2026-10-30 found the main firstmate broke this budget on 55% of captain messages.

`config/reply-first` is the per-home switch.
`on` enables the hook in that home, `off` disables it, and an absent file enables it only in a second mate home.
To adopt it in the main session, write `on` in the main home's `config/reply-first`.

## Registration

`bin/fm-spawn.sh` runs `bin/fm-mate-hooks-install.sh` for every second mate it launches.
The installer merges the two hooks into the home's untracked `.claude/settings.local.json`, once, and keeps other settings.
