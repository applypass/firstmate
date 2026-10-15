---
name: git-feature-branch
description: >-
  Create an ApplyPass feature git branch sc-<story-id>-<slug> off main when not
  already on a matching branch. Use when starting story work, before code
  changes, or when the user asks to create/switch to a feature branch.
---

# Git feature branch (sc-* off main)

Run in the **repo that will change** (e.g. `apply_pass_backend/`, `ai_backend/`).

## When to skip

**Do not create a branch** if current branch already matches the story in scope:

- Pattern: `sc-<story-id>-*` (e.g. `sc-5127-classes-airtable-api` for story `5127`)
- User explicitly says stay on current branch

If on a **different** `sc-*` branch than the story in scope → ask user whether to switch or create new branch for the new story.

## When to create

- On `main` (or any non-matching branch) and a story id is in scope
- User asks to create feature branch for `sc-<id>`

## Workflow

1. Resolve story numeric id from Shortcut story, user input, or branch context.
2. Choose slug: lowercase, hyphenated, brief (e.g. `classes-airtable-api`). Optional: `stories-get-branch-name` from Shortcut MCP, extended if too short.
3. Target branch: `sc-<story-id>-<slug>` (prefix **required**: `sc-<digits>` only).

```bash
git branch --show-current
git fetch origin main
git checkout main && git pull origin main
git checkout -b sc-<story-id>-<slug>
```

4. Verify: `git branch --show-current` → report branch name.

## Rules

- **Always branch off `main`**, never off another feature branch.
- Never commit on `main`; never start code edits while still on `main` without branching first.
- Uncommitted changes: carry them onto the new branch (do not discard unless user asks).
- Request `git_write` and network permissions for fetch/checkout.

## Output contract

```
Branch: sc-<id>-<slug>
Base: main (pulled)
Action: created | already on matching branch
```
