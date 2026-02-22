#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PID_FILE="$PROJECT_DIR/run/watcher.pid"
LOG_FILE="$PROJECT_DIR/logs/watcher.log"
WATCHER="$SCRIPT_DIR/codex_session_watcher.py"
QUIET="${1:-}"

mkdir -p "$PROJECT_DIR/run" "$PROJECT_DIR/logs"

if [[ -f "$PID_FILE" ]]; then
  PID="$(cat "$PID_FILE")"
  if [[ -n "$PID" ]] && kill -0 "$PID" >/dev/null 2>&1; then
    [[ "$QUIET" == "--quiet" ]] || echo "watcher already running (pid: $PID)"
    exit 0
  fi
  rm -f "$PID_FILE"
fi

nohup setsid "$WATCHER" --init-now </dev/null >>"$LOG_FILE" 2>&1 &
PID="$!"
echo "$PID" >"$PID_FILE"

sleep 0.4
if ! kill -0 "$PID" >/dev/null 2>&1; then
  rm -f "$PID_FILE"
  [[ "$QUIET" == "--quiet" ]] || {
    echo "watcher failed to start; check $LOG_FILE" >&2
    tail -n 40 "$LOG_FILE" >&2 || true
  }
  exit 1
fi

[[ "$QUIET" == "--quiet" ]] || echo "watcher started (pid: $PID)"
