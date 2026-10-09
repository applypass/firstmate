#!/usr/bin/env bash
# Runs a firstmate command against the disposable lab home with a fake token (no real credential) and a private tmux dir.
cd /Users/uayyagari/.no-mistakes/worktrees/c5d69c01912a/01M4FQYTZTDT0KFZXK6ZW83S1F
exec env -u TMUX -u TMUX_PANE -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u FM_SHORTCUT_TICKETS TMUX_TMPDIR=/var/folders/vr/_90lw3_s0bs_nw2f7b6t9yrm0000gn/T//fm-lab.7tFJpU/tmux FM_HOME=/var/folders/vr/_90lw3_s0bs_nw2f7b6t9yrm0000gn/T//fm-lab.7tFJpU SHORTCUT_API_TOKEN=fake-lab-token "$@"
