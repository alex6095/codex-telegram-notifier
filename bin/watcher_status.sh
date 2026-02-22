#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PID_FILE="$PROJECT_DIR/run/watcher.pid"
STATE_FILE="$HOME/.local/state/codex-telegram-notifier/state.json"

if [[ ! -f "$PID_FILE" ]]; then
  echo "watcher: stopped (no pid file)"
  exit 1
fi

PID="$(cat "$PID_FILE")"
if [[ -z "$PID" ]] || ! kill -0 "$PID" >/dev/null 2>&1; then
  echo "watcher: stopped (stale pid: ${PID:-none})"
  exit 1
fi

echo "watcher: running (pid: $PID)"
ps -p "$PID" -o etimes=,cmd=
if [[ -f "$STATE_FILE" ]]; then
  echo "state: $(stat -c '%y %n' "$STATE_FILE")"
fi
