#!/usr/bin/env bash
set -euo pipefail

SESSION="agents"
ROOT="/home/hunter/dev/treb"

if ! command -v tmux >/dev/null 2>&1; then
  echo "tmux is required but not installed." >&2
  exit 1
fi

if tmux has-session -t "$SESSION" 2>/dev/null; then
  exec tmux attach-session -t "$SESSION"
fi

tmux new-session -d -s "$SESSION" -c "$ROOT"
tmux send-keys -t "$SESSION":0.0 "cd $ROOT" C-m

tmux split-window -h -t "$SESSION":0 -c "$ROOT"
tmux split-window -v -t "$SESSION":0.1 -c "$ROOT"

tmux select-layout -t "$SESSION":0 tiled >/dev/null

tmux send-keys -t "$SESSION":0.0 "./script/run-burt-sandbox.sh"
tmux send-keys -t "$SESSION":0.1 "./script/run-treb-sandbox.sh"
tmux send-keys -t "$SESSION":0.2 "./script/run-astrid-sandbox.sh"

tmux select-pane -t "$SESSION":0.0
exec tmux attach-session -t "$SESSION"
