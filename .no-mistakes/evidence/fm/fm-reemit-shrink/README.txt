Live lab: real Claude Code primary (claude CLI, normal login) on a private tmux socket,
FM_HOME = disposable lab home (bin/fm-lab-home.sh create), cwd = plain clone of target 78c674e5 inside the lab
(the gate worktree itself stands down by design: fm_is_gate_agent path check in fm-sessionstart-run.sh).
Fixture: 12 tasks with 60-line status logs, 34.5 KB captain.md, 42 KB learnings.md.
live-claude-startup-full-digest.txt  - startup SessionStart hook stdout (101,146 bytes; Claude spilled it to a file)
live-claude-clear-reemit-1.txt       - /clear #1 re-emit as injected into context (6,583 chars, inline, not spilled)
live-claude-clear-reemit-2.txt       - /clear #2, no change (5,865 chars): tasks and context files named by file, not resent
live-claude-clear-reemit-3.txt       - /clear #3 after task-3 status change + real tasks-axi backlog (5,954 chars): task-3 resent;
                                       Backlog counts shows 4 unlabeled 'count: N' lines and a ready[2] header with no rows (defect)
live-reemit-3-full-digest-file.txt   - state/.reemit-full-digest.txt the summary points at
live-reemit-supervision-file.txt     - state/.reemit-supervision.txt the NEXT STEP points at
fm-reemit-shrink-test.log            - tests/fm-reemit-shrink.test.sh run
