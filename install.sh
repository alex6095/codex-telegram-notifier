#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASHRC="$HOME/.bashrc"
REAL_PATH_FILE="$PROJECT_DIR/.codex-real-path"
ENV_FILE="$PROJECT_DIR/.env"
ENV_EXAMPLE="$PROJECT_DIR/.env.example"
START_MARKER="# >>> codex-telegram-notifier >>>"
END_MARKER="# <<< codex-telegram-notifier <<<"

REAL_CODEX="$(command -v codex || true)"
if [[ -z "$REAL_CODEX" ]]; then
  echo "codex binary not found in PATH" >&2
  exit 1
fi

if [[ "$REAL_CODEX" == "$PROJECT_DIR/bin/codex_with_notify.sh" ]]; then
  if [[ -f "$REAL_PATH_FILE" ]]; then
    REAL_CODEX="$(cat "$REAL_PATH_FILE")"
  else
    echo "Could not resolve original codex binary" >&2
    exit 1
  fi
fi

printf '%s\n' "$REAL_CODEX" > "$REAL_PATH_FILE"

if [[ ! -f "$ENV_FILE" ]]; then
  cp "$ENV_EXAMPLE" "$ENV_FILE"
  echo "created $ENV_FILE"
fi

tmp_file="$(mktemp)"
if [[ -f "$BASHRC" ]]; then
  awk -v start="$START_MARKER" -v end="$END_MARKER" '
    $0 == start {skip=1; next}
    $0 == end {skip=0; next}
    !skip {print}
  ' "$BASHRC" > "$tmp_file"
else
  : > "$tmp_file"
fi

cat >> "$tmp_file" <<BASH_BLOCK
$START_MARKER
export CODEX_TELEGRAM_ENV="\$HOME/projects/codex-telegram-notifier/.env"
export CODEX_REAL_BIN="$REAL_CODEX"
codex() {
  "\$HOME/projects/codex-telegram-notifier/bin/codex_with_notify.sh" "\$@"
}
if [ -x "\$HOME/projects/codex-telegram-notifier/bin/start_watcher.sh" ]; then
  "\$HOME/projects/codex-telegram-notifier/bin/start_watcher.sh" --quiet
fi
$END_MARKER
BASH_BLOCK

mv "$tmp_file" "$BASHRC"

"$PROJECT_DIR/bin/start_watcher.sh" --quiet || true

echo "installed bash hook to $BASHRC"
echo "next: edit $ENV_FILE with TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID"
echo "then run: source ~/.bashrc"
