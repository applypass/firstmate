#!/usr/bin/env bash
# A pane that draws an empty claude-style composer and logs each submitted line.
log=$1
draw() { clear; printf '╭──────────────────────────────────────╮\n│ ❯                                     │\n╰──────────────────────────────────────╯\n'; }
draw
while IFS= read -r line; do printf '%s\n' "$line" >> "$log"; draw; done
