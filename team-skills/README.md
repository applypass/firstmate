# Team skills

Skills every ApplyPass engineer gets by running one command in a clone of this repo.
They are plain skill folders (`SKILL.md` plus helpers) that Claude Code, Codex, and other tools load from `~/.claude/skills` and `~/.agents/skills`.
This folder is fork-only: it does not exist in upstream firstmate.

## Install

```bash
git clone git@github.com:applypass/firstmate.git
cd firstmate
bin/fm-team-skills.sh --dry-run install   # show what would be linked
bin/fm-team-skills.sh install             # link every skill into both folders
bin/fm-team-skills.sh uninstall           # remove only the links this script made
```

Each skill becomes a symlink into this clone, so `git pull` updates every skill in place.
Install never overwrites: a path that already exists, or a link pointing elsewhere, is skipped and listed under "Conflicts".
Move that path yourself, then run install again.

## Skills

Third-party skills are copied in, not pinned.
Each folder holds its own `LICENSE` (when it has one) and a `SOURCE` note with the upstream repo and commit.
Updating one is a deliberate PR that re-copies from a newer commit and edits the `SOURCE` note.

| Skill | Source | License |
|---|---|---|
| grill-with-docs, diagnose, tdd, zoom-out, to-prd, to-issues, triage, handoff, improve-codebase-architecture, prototype, write-a-skill, setup-pre-commit, git-guardrails-claude-code | [mattpocock/skills](https://github.com/mattpocock/skills) at `aaf2453fbdfe7a15c07f11d861224f34ab4b53cb` | MIT |
| retro, writing-for-agents | [mattpocock/skills](https://github.com/mattpocock/skills) at `7a030a8b0dcaa601bb0dda9aaf174affb3d61145` (not present at the older commit) | MIT |
| show-me | [humanlayer/skills](https://github.com/humanlayer/skills) at `653b6411c1f70c275a18e37673b042ff99f67ceb`, with local changes listed in its `SOURCE` | MIT |
| software-factory | ApplyPass write-up, based on Dex Horthy's 4-gate workflow (HumanLayer); no upstream file found | none |
| shortcut-story, git-feature-branch | ApplyPass internal | none |

## Left out on purpose

- Skills that ship with their tools: no-mistakes, orca-cli, orchestration, computer-use.
- Firstmate's own skills under `.agents/skills/`: they only make sense inside a firstmate home.
- Personal skills (time tracking, notes, writing, and similar).
