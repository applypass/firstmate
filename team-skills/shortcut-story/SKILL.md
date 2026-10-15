---
name: shortcut-story
description: >-
  Create or retrieve an ApplyPass Shortcut story via MCP (user-shortcut).
  Use when the user asks for a Shortcut ticket/story, sc-* story id, needs
  In Progress set, or before starting tracked work without a story yet.
---

# Shortcut story (create or retrieve)

MCP server: **`user-shortcut`**. Read tool schemas under `mcps/user-shortcut/tools/` before calling. Authenticate with `mcp_auth` if tools fail.

## When to retrieve vs create

**Retrieve** (do not create) when any of these is true:

- User gave a story id or link (`sc-5127`, `https://app.shortcut.com/applypass/story/5127`)
- User says retrieve/get/fetch existing story
- Current git branch matches `sc-<digits>-*` — extract numeric id and fetch that story

**Create** when none apply and the user wants a new ticket for upcoming work.

**Skip entirely** when user says "no ticket" or "skip shortcut".

## Retrieve workflow

1. Parse story id from input or branch name (`sc-5127-foo` → `5127`).
2. `CallMcpTool` → `stories-get-by-id` with `{ "storyPublicId": <id> }`.
3. Return to user:
   - Story URL: `https://app.shortcut.com/applypass/story/<id>`
   - Public id: `sc-<id>`
   - Name, state, owner

If id unknown but user gave keywords → `stories-search` (e.g. `{ "name": "...", "owner": "me" }`); confirm match with user if ambiguous.

## Create workflow

1. **If task is vague** (no goal, scope, or repo) → ask user before creating.
2. `users-get-current` → note `id` for owner assignment.
3. `workflows-get-default` → use default workflow (ApplyPass: **Standard**); note **In Progress** state id (`workflow_state_id`).
4. `stories-create`:
   - `name`: short, actionable summary
   - `description`: goal, scope, repo/path, acceptance criteria, links
   - `type`: `feature` | `bug` | `chore`
   - `workflow`: default workflow id
   - `owner`: current user id from step 2
5. `stories-update` → set **In Progress** via `workflow_state_id`.
6. Return story URL and `sc-<id>`.

## Output contract

Always report:

```
Story: sc-<id> — <name>
URL: https://app.shortcut.com/applypass/story/<id>
State: <workflow state>
Action: created | retrieved
```

Pass `storyPublicId`, `storyUrl`, and `storyName` to downstream steps (git branch, Toggl).

## Optional

- `stories-get-branch-name` for Shortcut’s suggested branch slug (extend if too short).
