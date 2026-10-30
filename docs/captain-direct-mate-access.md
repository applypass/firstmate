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
A read outside the home is refused too: every absolute, `~`, or `..` path in a command must be under the home, and arguments must be written out, not built from variables.
Git runs only read subcommands, with no `-c` and no option that runs a program.
The check stops safely: a payload it cannot read or parse is refused.

For a second mate home there is one exception.
An order is queued to the owning mate's steering inbox through `bin/fm-ask-order.sh`, which calls `bin/fm-send.sh`.
The target is fixed by the launcher, so the session cannot redirect it.
The session replies "queued" and says what the mate's latest status shows it doing.

Routing order for a question about a second mate's work: the owning mate, then a read-only session on that mate's home, then main last.

## Reply first

`bin/fm-reply-first.sh` counts tool calls after a message that expects an answer.
After 3 calls without a reply, the next call is refused once with "answer now with what you have, hand the rest off".
The window opens only for a message the captain typed into the pane, and not for a slash command such as `/afk`, which runs a skill rather than asks a question.
Every other prompt (the steering doorbell, a `[fm-from-firstmate]` message, operational input, a Stop hook wake, a harness notification) closes any open window, so work routed to the agent is never refused its fourth command.
In the primary home a task notification leaves the window alone: a background launch that finishes mid-answer does not switch the count off.
A reply is a `bin/fm-secondmate-report.sh` call, assistant text of 200 characters or more, or shorter text that addresses the captain.
Text addresses the captain when "captain" (any case) stands as its own word, not inside a name or path such as `fm-captain-hold.sh`, with a comma before it or `, . ! ? : ;` or the end of the text after it.
So "Captain, shipshape.", "Aye, captain - done." and "Done, captain." count; "Let me see what the captain asked" does not.
A command that runs `bin/fm-send.sh`, `bin/fm-spawn.sh`, `bin/fm-dispatch-resolve.sh`, or `bin/fm-brief.sh` (the first word of a segment split at `;`, `&`, `|`, after any `VAR=value` and a `bash`, `sh`, `env`, or `timeout N` wrapper, quotes stripped) is never counted or refused; reading one of those scripts counts: handing the rest off is what the refusal asks for.
`FM_REPLY_FIRST_LIMIT` and `FM_REPLY_FIRST_MIN_CHARS` tune it; the word `off` in `config/reply-first` turns it off for a home.
The latency report of 2026-10-30 found the main firstmate broke this budget on 52-55% of captain messages, and those replies were 85% of all waiting time.

It runs in a second mate home and in the primary home.
In the primary home the prompt hook is `bin/fm-reply-first.sh prompt`, and a Stop hook runs `bin/fm-reply-first.sh clear` so a wake turn after a finished captain turn is never counted.
For a Claude primary session the supervision instructions carry one rule line: answer first, hand digging to a worker or second mate, and run `bin/fm-spawn.sh`, `bin/fm-dispatch-resolve.sh`, and `bin/fm-shortcut-ticket.sh` with the Bash tool's `run_in_background` so the reply is not held behind them.
The Bash tool returns at once, keeps the command's own guards and output, and wakes the agent when it exits.

Measure it with the latency report's method on a main session transcript:

```text
python3 bin/fm-reply-latency.py <transcript.jsonl> [--since <ISO time|epoch>]
```

It prints the share of captain messages with more than 3 commands before the reply, and the median and p90 wait.

## Registration

`bin/fm-spawn.sh` runs `bin/fm-mate-hooks-install.sh` for every second mate it launches.
The installer merges the two hooks into the home's untracked `.claude/settings.local.json`, once, and keeps other settings.
`bin/fm-session-start.sh` runs `bin/fm-mate-hooks-install.sh --main` for the primary home on each full locked start; it registers reply-first's prompt, PreToolUse, and Stop hooks and skips a second mate home.
