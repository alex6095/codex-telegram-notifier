#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REAL_PATH_FILE="$PROJECT_DIR/.codex-real-path"
NOTIFIER="$SCRIPT_DIR/telegram_notify.sh"

resolve_real_codex() {
  if [[ -n "${CODEX_REAL_BIN:-}" && -x "${CODEX_REAL_BIN}" ]]; then
    printf '%s\n' "$CODEX_REAL_BIN"
    return 0
  fi

  if [[ -f "$REAL_PATH_FILE" ]]; then
    local saved
    saved="$(cat "$REAL_PATH_FILE")"
    if [[ -x "$saved" ]]; then
      printf '%s\n' "$saved"
      return 0
    fi
  fi

  local self_path
  self_path="$(readlink -f "$0")"

  local candidate
  while IFS= read -r candidate; do
    [[ -z "$candidate" ]] && continue
    if [[ "$(readlink -f "$candidate")" != "$self_path" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done < <(which -a codex 2>/dev/null | awk '!seen[$0]++')

  return 1
}

REAL_CODEX="$(resolve_real_codex || true)"
if [[ -z "$REAL_CODEX" ]]; then
  echo "Could not resolve real codex binary" >&2
  exit 1
fi

START_TS="$(date +%s)"
START_HUMAN="$(date '+%Y-%m-%d %H:%M:%S')"
WORKDIR="$(pwd)"
ARGS="$*"

set +e
"$REAL_CODEX" "$@"
CODEX_EXIT=$?
set -e

END_TS="$(date +%s)"
DURATION=$((END_TS - START_TS))
STATUS="SUCCESS"
if [[ $CODEX_EXIT -ne 0 ]]; then
  STATUS="FAILED"
fi

MESSAGE=$(cat <<MSG
[$STATUS] Codex process finished
started: $START_HUMAN
cwd: $WORKDIR
seconds: $DURATION
exit_code: $CODEX_EXIT
args: ${ARGS:-<none>}
MSG
)

if [[ -x "$NOTIFIER" ]]; then
  "$NOTIFIER" "$MESSAGE" >/dev/null 2>&1 || true
fi

exit "$CODEX_EXIT"
