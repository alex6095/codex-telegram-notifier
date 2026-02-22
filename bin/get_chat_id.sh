#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="${CODEX_TELEGRAM_ENV:-$PROJECT_DIR/.env}"

if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

: "${TELEGRAM_BOT_TOKEN:?TELEGRAM_BOT_TOKEN is not set (check $ENV_FILE)}"
export TELEGRAM_BOT_TOKEN

if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required" >&2
  exit 1
fi

python3 - <<'PY'
import json
import os
import subprocess
import sys

token = os.environ.get("TELEGRAM_BOT_TOKEN")
if not token:
    print("TELEGRAM_BOT_TOKEN is missing", file=sys.stderr)
    raise SystemExit(1)

url = f"https://api.telegram.org/bot{token}/getUpdates"
resp = subprocess.check_output(["curl", "-sS", "--fail", url], text=True)
data = json.loads(resp)

seen = set()
for item in data.get("result", []):
    message = item.get("message") or item.get("edited_message") or {}
    chat = message.get("chat") or {}
    chat_id = chat.get("id")
    if chat_id in seen:
        continue
    seen.add(chat_id)
    title = chat.get("title") or chat.get("username") or chat.get("first_name") or "unknown"
    print(f"chat_id={chat_id} title={title}")

if not seen:
    print("No chats found. Send /start to your bot, then run this again.")
PY
