#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="${CODEX_TELEGRAM_ENV:-$PROJECT_DIR/.env}"

if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required" >&2
  exit 1
fi

: "${TELEGRAM_BOT_TOKEN:?TELEGRAM_BOT_TOKEN is not set (check $ENV_FILE)}"
: "${TELEGRAM_CHAT_ID:?TELEGRAM_CHAT_ID is not set (check $ENV_FILE)}"
TELEGRAM_PARSE_MODE="${TELEGRAM_PARSE_MODE:-HTML}"
TELEGRAM_TURN_ID_MODE="${TELEGRAM_TURN_ID_MODE:-both}"  # both | topic | session
TELEGRAM_FULL_REPLY="${TELEGRAM_FULL_REPLY:-true}"
TELEGRAM_REPLY_PARSE_MODE="${TELEGRAM_REPLY_PARSE_MODE:-auto}"  # auto | HTML | MarkdownV2 | Markdown | plain
TELEGRAM_REPLY_CHUNK_CHARS="${TELEGRAM_REPLY_CHUNK_CHARS:-3500}"
TELEGRAM_TIMEZONE="${TELEGRAM_TIMEZONE:-Asia/Seoul}"

if [[ $# -gt 0 ]]; then
  MESSAGE="$*"
else
  MESSAGE="$(cat)"
fi

if [[ -z "${MESSAGE// }" ]]; then
  echo "message is empty" >&2
  exit 1
fi

RAW_MESSAGE="$MESSAGE"

escape_html() {
  sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

escape_inline() {
  printf '%s' "$1" | escape_html
}

format_timestamp_for_display() {
  local raw="$1"
  local formatted=""
  if [[ -z "$raw" ]]; then
    echo ""
    return
  fi
  formatted="$(TZ="$TELEGRAM_TIMEZONE" date -d "$raw" '+%Y-%m-%d %H:%M:%S (%Z)' 2>/dev/null || true)"
  if [[ -n "$formatted" ]]; then
    echo "$formatted"
  else
    echo "$raw"
  fi
}

sanitize_reply_text() {
  local input="$1"
  python3 - "$input" <<'PY'
import sys

text = sys.argv[1].replace("\r\n", "\n")
lines = text.split("\n")

nonempty = [idx for idx, line in enumerate(lines) if line.strip()]
if nonempty:
    first_idx = nonempty[0]
    last_idx = nonempty[-1]
    first = lines[first_idx].strip()
    last = lines[last_idx].strip()
    if first == "<proposed_plan>" and last == "</proposed_plan>":
        lines = lines[first_idx + 1:last_idx]
        while lines and not lines[0].strip():
            lines = lines[1:]
        while lines and not lines[-1].strip():
            lines = lines[:-1]
        text = "\n".join(lines)

sys.stdout.write(text)
PY
}

format_reply_html_block() {
  local reply_text="$1"
  local cleaned reply_mode rendered

  cleaned="$(sanitize_reply_text "$reply_text")"
  if [[ -z "$cleaned" ]]; then
    cleaned="<empty>"
  fi

  reply_mode="$(resolve_reply_mode)"
  if [[ "$reply_mode" == "HTML_MARKDOWN" ]]; then
    rendered="$(markdown_to_html "$cleaned")"
    if [[ -z "${rendered// }" ]]; then
      printf '<pre>%s</pre>' "$(printf '%s' "$cleaned" | escape_html)"
    else
      printf '%s' "$rendered"
    fi
    return 0
  fi

  printf '<pre>%s</pre>' "$(printf '%s' "$cleaned" | escape_html)"
}

format_html_message() {
  local raw="$1"
  local first_line
  first_line="$(printf '%s\n' "$raw" | head -n 1)"

  if [[ "$first_line" =~ ^\[Codex\ (Turn|Task)\ Complete\]$ ]]; then
    local session cwd topic timestamp reply_block id_mode
    session="$(printf '%s\n' "$raw" | sed -n 's/^session: //p' | head -n 1)"
    cwd="$(printf '%s\n' "$raw" | sed -n 's/^cwd: //p' | head -n 1)"
    topic="$(printf '%s\n' "$raw" | sed -n 's/^topic: //p' | head -n 1)"
    timestamp="$(printf '%s\n' "$raw" | sed -n 's/^time: //p' | head -n 1)"
    timestamp="$(format_timestamp_for_display "$timestamp")"
    reply_block="$(printf '%s\n' "$raw" | sed -n '/^reply: /,$p')"
    reply_block="${reply_block#reply: }"
    reply_block="$(sanitize_reply_text "$reply_block")"
    if [[ -z "$reply_block" ]]; then
      reply_block="<empty>"
    fi
    id_mode="${TELEGRAM_TURN_ID_MODE,,}"

    printf '<b>Codex %s Complete</b>\n' "$(escape_inline "${BASH_REMATCH[1]}")"
    if [[ -n "$cwd" ]]; then
      printf '<b>CWD</b>: <code>%s</code>\n' "$(escape_inline "$cwd")"
    fi
    if [[ "$id_mode" == "topic" ]]; then
      if [[ -n "$topic" ]]; then
        printf '<b>Topic</b>: <code>%s</code>\n' "$(escape_inline "$topic")"
      else
        printf '<b>Session</b>: <code>%s</code>\n' "$(escape_inline "$session")"
      fi
    elif [[ "$id_mode" == "session" ]]; then
      printf '<b>Session</b>: <code>%s</code>\n' "$(escape_inline "$session")"
    else
      if [[ -n "$topic" ]]; then
        printf '<b>Topic</b>: <code>%s</code>\n' "$(escape_inline "$topic")"
      fi
      printf '<b>Session</b>: <code>%s</code>\n' "$(escape_inline "$session")"
    fi
    printf '<b>Time</b>: <code>%s</code>\n' "$(escape_inline "$timestamp")"
    printf '<b>Reply</b>\n%s' "$(format_reply_html_block "$reply_block")"
    return 0
  fi

  if [[ "$first_line" == "[Codex Assistant Plan]" ]]; then
    local session cwd topic timestamp reply_block id_mode
    session="$(printf '%s\n' "$raw" | sed -n 's/^session: //p' | head -n 1)"
    cwd="$(printf '%s\n' "$raw" | sed -n 's/^cwd: //p' | head -n 1)"
    topic="$(printf '%s\n' "$raw" | sed -n 's/^topic: //p' | head -n 1)"
    timestamp="$(printf '%s\n' "$raw" | sed -n 's/^time: //p' | head -n 1)"
    timestamp="$(format_timestamp_for_display "$timestamp")"
    reply_block="$(printf '%s\n' "$raw" | sed -n '/^reply: /,$p')"
    reply_block="${reply_block#reply: }"
    reply_block="$(sanitize_reply_text "$reply_block")"
    [[ -z "$reply_block" ]] && reply_block="<empty>"
    id_mode="${TELEGRAM_TURN_ID_MODE,,}"

    printf '<b>Codex Assistant Plan</b>\n'
    if [[ -n "$cwd" ]]; then
      printf '<b>CWD</b>: <code>%s</code>\n' "$(escape_inline "$cwd")"
    fi
    if [[ "$id_mode" == "topic" ]]; then
      if [[ -n "$topic" ]]; then
        printf '<b>Topic</b>: <code>%s</code>\n' "$(escape_inline "$topic")"
      else
        printf '<b>Session</b>: <code>%s</code>\n' "$(escape_inline "$session")"
      fi
    elif [[ "$id_mode" == "session" ]]; then
      printf '<b>Session</b>: <code>%s</code>\n' "$(escape_inline "$session")"
    else
      if [[ -n "$topic" ]]; then
        printf '<b>Topic</b>: <code>%s</code>\n' "$(escape_inline "$topic")"
      fi
      printf '<b>Session</b>: <code>%s</code>\n' "$(escape_inline "$session")"
    fi
    printf '<b>Time</b>: <code>%s</code>\n' "$(escape_inline "$timestamp")"
    printf '<b>Reply</b>\n%s' "$(format_reply_html_block "$reply_block")"
    return 0
  fi

  if [[ "$first_line" == "[Codex Action Required]" ]]; then
    local session cwd topic timestamp question_block id_mode
    session="$(printf '%s\n' "$raw" | sed -n 's/^session: //p' | head -n 1)"
    cwd="$(printf '%s\n' "$raw" | sed -n 's/^cwd: //p' | head -n 1)"
    topic="$(printf '%s\n' "$raw" | sed -n 's/^topic: //p' | head -n 1)"
    timestamp="$(printf '%s\n' "$raw" | sed -n 's/^time: //p' | head -n 1)"
    timestamp="$(format_timestamp_for_display "$timestamp")"
    question_block="$(printf '%s\n' "$raw" | sed -n '/^question: /,$p')"
    question_block="${question_block#question: }"
    [[ -z "$question_block" ]] && question_block="Codex is waiting for your input."
    id_mode="${TELEGRAM_TURN_ID_MODE,,}"

    printf '<b>Codex Action Required</b>\n'
    if [[ -n "$cwd" ]]; then
      printf '<b>CWD</b>: <code>%s</code>\n' "$(escape_inline "$cwd")"
    fi
    if [[ "$id_mode" == "topic" ]]; then
      if [[ -n "$topic" ]]; then
        printf '<b>Topic</b>: <code>%s</code>\n' "$(escape_inline "$topic")"
      else
        printf '<b>Session</b>: <code>%s</code>\n' "$(escape_inline "$session")"
      fi
    elif [[ "$id_mode" == "session" ]]; then
      printf '<b>Session</b>: <code>%s</code>\n' "$(escape_inline "$session")"
    else
      if [[ -n "$topic" ]]; then
        printf '<b>Topic</b>: <code>%s</code>\n' "$(escape_inline "$topic")"
      fi
      printf '<b>Session</b>: <code>%s</code>\n' "$(escape_inline "$session")"
    fi
    printf '<b>Time</b>: <code>%s</code>\n' "$(escape_inline "$timestamp")"
    printf '<b>Question</b>\n<pre>%s</pre>' "$(printf '%s' "$question_block" | escape_html)"
    return 0
  fi

  if [[ "$first_line" == "[Codex Plan Updated]" ]]; then
    local session cwd topic timestamp plan_block id_mode
    session="$(printf '%s\n' "$raw" | sed -n 's/^session: //p' | head -n 1)"
    cwd="$(printf '%s\n' "$raw" | sed -n 's/^cwd: //p' | head -n 1)"
    topic="$(printf '%s\n' "$raw" | sed -n 's/^topic: //p' | head -n 1)"
    timestamp="$(printf '%s\n' "$raw" | sed -n 's/^time: //p' | head -n 1)"
    timestamp="$(format_timestamp_for_display "$timestamp")"
    plan_block="$(printf '%s\n' "$raw" | sed -n '/^plan: /,$p')"
    plan_block="${plan_block#plan: }"
    [[ -z "$plan_block" ]] && plan_block="Plan updated."
    id_mode="${TELEGRAM_TURN_ID_MODE,,}"

    printf '<b>Codex Plan Updated</b>\n'
    if [[ -n "$cwd" ]]; then
      printf '<b>CWD</b>: <code>%s</code>\n' "$(escape_inline "$cwd")"
    fi
    if [[ "$id_mode" == "topic" ]]; then
      if [[ -n "$topic" ]]; then
        printf '<b>Topic</b>: <code>%s</code>\n' "$(escape_inline "$topic")"
      else
        printf '<b>Session</b>: <code>%s</code>\n' "$(escape_inline "$session")"
      fi
    elif [[ "$id_mode" == "session" ]]; then
      printf '<b>Session</b>: <code>%s</code>\n' "$(escape_inline "$session")"
    else
      if [[ -n "$topic" ]]; then
        printf '<b>Topic</b>: <code>%s</code>\n' "$(escape_inline "$topic")"
      fi
      printf '<b>Session</b>: <code>%s</code>\n' "$(escape_inline "$session")"
    fi
    printf '<b>Time</b>: <code>%s</code>\n' "$(escape_inline "$timestamp")"
    printf '<b>Plan</b>\n<pre>%s</pre>' "$(printf '%s' "$plan_block" | escape_html)"
    return 0
  fi

  if [[ "$first_line" =~ ^\[(SUCCESS|FAILED)\]\ Codex\ process\ finished$ ]]; then
    local status started cwd seconds exit_code args
    status="${BASH_REMATCH[1]}"
    started="$(printf '%s\n' "$raw" | sed -n 's/^started: //p' | head -n 1)"
    cwd="$(printf '%s\n' "$raw" | sed -n 's/^cwd: //p' | head -n 1)"
    seconds="$(printf '%s\n' "$raw" | sed -n 's/^seconds: //p' | head -n 1)"
    exit_code="$(printf '%s\n' "$raw" | sed -n 's/^exit_code: //p' | head -n 1)"
    args="$(printf '%s\n' "$raw" | sed -n 's/^args: //p' | head -n 1)"
    [[ -z "$args" ]] && args="<none>"

    printf '<b>Codex Run %s</b>\n' "$(escape_inline "$status")"
    printf '<b>Started</b>: <code>%s</code>\n' "$(escape_inline "$started")"
    printf '<b>CWD</b>: <code>%s</code>\n' "$(escape_inline "$cwd")"
    printf '<b>Duration</b>: <code>%ss</code>\n' "$(escape_inline "$seconds")"
    printf '<b>Exit</b>: <code>%s</code>\n' "$(escape_inline "$exit_code")"
    printf '<b>Args</b>: <pre>%s</pre>' "$(printf '%s' "$args" | escape_html)"
    return 0
  fi

  printf '<b>Codex Notification</b>\n<pre>%s</pre>' "$(printf '%s' "$raw" | escape_html)"
}

escape_markdown_v2() {
  sed \
    -e 's/\\/\\\\/g' \
    -e 's/_/\\_/g' \
    -e 's/\*/\\*/g' \
    -e 's/\[/\\[/g' \
    -e 's/\]/\\]/g' \
    -e 's/(/\\(/g' \
    -e 's/)/\\)/g' \
    -e 's/~/\\~/g' \
    -e 's/`/\\`/g' \
    -e 's/>/\\>/g' \
    -e 's/#/\\#/g' \
    -e 's/+/\\+/g' \
    -e 's/-/\\-/g' \
    -e 's/=/\\=/g' \
    -e 's/|/\\|/g' \
    -e 's/{/\\{/g' \
    -e 's/}/\\}/g' \
    -e 's/\./\\./g' \
    -e 's/!/\\!/g'
}

format_markdown_v2_message() {
  local raw="$1"
  local first_line
  first_line="$(printf '%s\n' "$raw" | head -n 1)"

  if [[ "$first_line" =~ ^\[Codex\ (Turn|Task)\ Complete\]$ ]]; then
    local kind session cwd topic timestamp reply_block id_mode
    kind="${BASH_REMATCH[1]}"
    session="$(printf '%s\n' "$raw" | sed -n 's/^session: //p' | head -n 1)"
    cwd="$(printf '%s\n' "$raw" | sed -n 's/^cwd: //p' | head -n 1)"
    topic="$(printf '%s\n' "$raw" | sed -n 's/^topic: //p' | head -n 1)"
    timestamp="$(printf '%s\n' "$raw" | sed -n 's/^time: //p' | head -n 1)"
    timestamp="$(format_timestamp_for_display "$timestamp")"
    reply_block="$(printf '%s\n' "$raw" | sed -n '/^reply: /,$p')"
    reply_block="${reply_block#reply: }"
    reply_block="$(sanitize_reply_text "$reply_block")"
    [[ -z "$reply_block" ]] && reply_block="<empty>"
    id_mode="${TELEGRAM_TURN_ID_MODE,,}"

    printf '*Codex %s Complete*\n' "$(printf '%s' "$kind" | escape_markdown_v2)"
    if [[ -n "$cwd" ]]; then
      printf '*CWD*: %s\n' "$(printf '%s' "$cwd" | escape_markdown_v2)"
    fi
    if [[ "$id_mode" == "topic" ]]; then
      if [[ -n "$topic" ]]; then
        printf '*Topic*: %s\n' "$(printf '%s' "$topic" | escape_markdown_v2)"
      else
        printf '*Session*: %s\n' "$(printf '%s' "$session" | escape_markdown_v2)"
      fi
    elif [[ "$id_mode" == "session" ]]; then
      printf '*Session*: %s\n' "$(printf '%s' "$session" | escape_markdown_v2)"
    else
      if [[ -n "$topic" ]]; then
        printf '*Topic*: %s\n' "$(printf '%s' "$topic" | escape_markdown_v2)"
      fi
      printf '*Session*: %s\n' "$(printf '%s' "$session" | escape_markdown_v2)"
    fi
    printf '*Time*: %s\n' "$(printf '%s' "$timestamp" | escape_markdown_v2)"
    printf '*Reply*\n%s' "$(printf '%s' "$reply_block" | escape_markdown_v2)"
    return 0
  fi

  if [[ "$first_line" == "[Codex Assistant Plan]" ]]; then
    local session cwd topic timestamp reply_block id_mode
    session="$(printf '%s\n' "$raw" | sed -n 's/^session: //p' | head -n 1)"
    cwd="$(printf '%s\n' "$raw" | sed -n 's/^cwd: //p' | head -n 1)"
    topic="$(printf '%s\n' "$raw" | sed -n 's/^topic: //p' | head -n 1)"
    timestamp="$(printf '%s\n' "$raw" | sed -n 's/^time: //p' | head -n 1)"
    timestamp="$(format_timestamp_for_display "$timestamp")"
    reply_block="$(printf '%s\n' "$raw" | sed -n '/^reply: /,$p')"
    reply_block="${reply_block#reply: }"
    reply_block="$(sanitize_reply_text "$reply_block")"
    [[ -z "$reply_block" ]] && reply_block="<empty>"
    id_mode="${TELEGRAM_TURN_ID_MODE,,}"

    printf '*Codex Assistant Plan*\n'
    if [[ -n "$cwd" ]]; then
      printf '*CWD*: %s\n' "$(printf '%s' "$cwd" | escape_markdown_v2)"
    fi
    if [[ "$id_mode" == "topic" ]]; then
      if [[ -n "$topic" ]]; then
        printf '*Topic*: %s\n' "$(printf '%s' "$topic" | escape_markdown_v2)"
      else
        printf '*Session*: %s\n' "$(printf '%s' "$session" | escape_markdown_v2)"
      fi
    elif [[ "$id_mode" == "session" ]]; then
      printf '*Session*: %s\n' "$(printf '%s' "$session" | escape_markdown_v2)"
    else
      if [[ -n "$topic" ]]; then
        printf '*Topic*: %s\n' "$(printf '%s' "$topic" | escape_markdown_v2)"
      fi
      printf '*Session*: %s\n' "$(printf '%s' "$session" | escape_markdown_v2)"
    fi
    printf '*Time*: %s\n' "$(printf '%s' "$timestamp" | escape_markdown_v2)"
    printf '*Reply*\n%s' "$(printf '%s' "$reply_block" | escape_markdown_v2)"
    return 0
  fi

  if [[ "$first_line" == "[Codex Action Required]" ]]; then
    local session cwd topic timestamp question_block id_mode
    session="$(printf '%s\n' "$raw" | sed -n 's/^session: //p' | head -n 1)"
    cwd="$(printf '%s\n' "$raw" | sed -n 's/^cwd: //p' | head -n 1)"
    topic="$(printf '%s\n' "$raw" | sed -n 's/^topic: //p' | head -n 1)"
    timestamp="$(printf '%s\n' "$raw" | sed -n 's/^time: //p' | head -n 1)"
    timestamp="$(format_timestamp_for_display "$timestamp")"
    question_block="$(printf '%s\n' "$raw" | sed -n '/^question: /,$p')"
    question_block="${question_block#question: }"
    [[ -z "$question_block" ]] && question_block="Codex is waiting for your input."
    id_mode="${TELEGRAM_TURN_ID_MODE,,}"

    printf '*Codex Action Required*\n'
    if [[ -n "$cwd" ]]; then
      printf '*CWD*: %s\n' "$(printf '%s' "$cwd" | escape_markdown_v2)"
    fi
    if [[ "$id_mode" == "topic" ]]; then
      if [[ -n "$topic" ]]; then
        printf '*Topic*: %s\n' "$(printf '%s' "$topic" | escape_markdown_v2)"
      else
        printf '*Session*: %s\n' "$(printf '%s' "$session" | escape_markdown_v2)"
      fi
    elif [[ "$id_mode" == "session" ]]; then
      printf '*Session*: %s\n' "$(printf '%s' "$session" | escape_markdown_v2)"
    else
      if [[ -n "$topic" ]]; then
        printf '*Topic*: %s\n' "$(printf '%s' "$topic" | escape_markdown_v2)"
      fi
      printf '*Session*: %s\n' "$(printf '%s' "$session" | escape_markdown_v2)"
    fi
    printf '*Time*: %s\n' "$(printf '%s' "$timestamp" | escape_markdown_v2)"
    printf '*Question*\n%s' "$(printf '%s' "$question_block" | escape_markdown_v2)"
    return 0
  fi

  if [[ "$first_line" == "[Codex Plan Updated]" ]]; then
    local session cwd topic timestamp plan_block id_mode
    session="$(printf '%s\n' "$raw" | sed -n 's/^session: //p' | head -n 1)"
    cwd="$(printf '%s\n' "$raw" | sed -n 's/^cwd: //p' | head -n 1)"
    topic="$(printf '%s\n' "$raw" | sed -n 's/^topic: //p' | head -n 1)"
    timestamp="$(printf '%s\n' "$raw" | sed -n 's/^time: //p' | head -n 1)"
    timestamp="$(format_timestamp_for_display "$timestamp")"
    plan_block="$(printf '%s\n' "$raw" | sed -n '/^plan: /,$p')"
    plan_block="${plan_block#plan: }"
    [[ -z "$plan_block" ]] && plan_block="Plan updated."
    id_mode="${TELEGRAM_TURN_ID_MODE,,}"

    printf '*Codex Plan Updated*\n'
    if [[ -n "$cwd" ]]; then
      printf '*CWD*: %s\n' "$(printf '%s' "$cwd" | escape_markdown_v2)"
    fi
    if [[ "$id_mode" == "topic" ]]; then
      if [[ -n "$topic" ]]; then
        printf '*Topic*: %s\n' "$(printf '%s' "$topic" | escape_markdown_v2)"
      else
        printf '*Session*: %s\n' "$(printf '%s' "$session" | escape_markdown_v2)"
      fi
    elif [[ "$id_mode" == "session" ]]; then
      printf '*Session*: %s\n' "$(printf '%s' "$session" | escape_markdown_v2)"
    else
      if [[ -n "$topic" ]]; then
        printf '*Topic*: %s\n' "$(printf '%s' "$topic" | escape_markdown_v2)"
      fi
      printf '*Session*: %s\n' "$(printf '%s' "$session" | escape_markdown_v2)"
    fi
    printf '*Time*: %s\n' "$(printf '%s' "$timestamp" | escape_markdown_v2)"
    printf '*Plan*\n%s' "$(printf '%s' "$plan_block" | escape_markdown_v2)"
    return 0
  fi

  if [[ "$first_line" =~ ^\[(SUCCESS|FAILED)\]\ Codex\ process\ finished$ ]]; then
    local status started cwd seconds exit_code args
    status="${BASH_REMATCH[1]}"
    started="$(printf '%s\n' "$raw" | sed -n 's/^started: //p' | head -n 1)"
    cwd="$(printf '%s\n' "$raw" | sed -n 's/^cwd: //p' | head -n 1)"
    seconds="$(printf '%s\n' "$raw" | sed -n 's/^seconds: //p' | head -n 1)"
    exit_code="$(printf '%s\n' "$raw" | sed -n 's/^exit_code: //p' | head -n 1)"
    args="$(printf '%s\n' "$raw" | sed -n 's/^args: //p' | head -n 1)"
    [[ -z "$args" ]] && args="<none>"

    printf '*Codex Run %s*\n' "$(printf '%s' "$status" | escape_markdown_v2)"
    printf '*Started*: %s\n' "$(printf '%s' "$started" | escape_markdown_v2)"
    printf '*CWD*: %s\n' "$(printf '%s' "$cwd" | escape_markdown_v2)"
    printf '*Duration*: %ss\n' "$(printf '%s' "$seconds" | escape_markdown_v2)"
    printf '*Exit*: %s\n' "$(printf '%s' "$exit_code" | escape_markdown_v2)"
    printf '*Args*\n%s' "$(printf '%s' "$args" | escape_markdown_v2)"
    return 0
  fi

  printf '*Codex Notification*\n%s' "$(printf '%s' "$raw" | escape_markdown_v2)"
}

send_message() {
  local mode="$1"
  local text="$2"
  local -a curl_args

  curl_args=(
    -sS
    --fail
    -X POST
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage"
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}"
    --data-urlencode "text=${text}"
    --data-urlencode "disable_web_page_preview=true"
  )
  if [[ -n "$mode" ]]; then
    curl_args+=(--data-urlencode "parse_mode=${mode}")
  fi

  curl "${curl_args[@]}" >/dev/null
}

is_truthy() {
  case "${1,,}" in
    1|true|yes|y|on)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

normalize_reply_chunk_chars() {
  local raw="${TELEGRAM_REPLY_CHUNK_CHARS}"
  if [[ "$raw" =~ ^[0-9]+$ ]]; then
    if (( raw < 200 )); then
      echo 200
      return
    fi
    if (( raw > 3900 )); then
      echo 3900
      return
    fi
    echo "$raw"
    return
  fi
  echo 3500
}

resolve_reply_mode() {
  local configured="${TELEGRAM_REPLY_PARSE_MODE}"
  case "${configured,,}" in
    auto)
      # Render markdown-ish replies reliably by converting to Telegram HTML.
      echo "HTML_MARKDOWN"
      ;;
    markdownv2)
      echo "MarkdownV2"
      ;;
    markdown)
      echo "Markdown"
      ;;
    html)
      echo "HTML"
      ;;
    plain|"")
      echo ""
      ;;
    *)
      echo "$configured"
      ;;
  esac
}

send_with_fallback() {
  local mode="$1"
  local formatted="$2"
  local raw_fallback="$3"
  if send_message "$mode" "$formatted"; then
    return 0
  fi
  echo "telegram_notify: send with parse mode '${mode:-none}' failed; retrying plain text" >&2
  send_message "" "$raw_fallback"
}

send_reply_chunks() {
  local reply_text="$1"
  local preferred_mode="$2"
  local chunk_chars="$3"
  local total_len="${#reply_text}"
  local offset=0
  local chunk
  local formatted
  local mode

  while (( offset < total_len )); do
    chunk="${reply_text:offset:chunk_chars}"
    formatted="$chunk"
    mode="$preferred_mode"

    if [[ "$preferred_mode" == "HTML_MARKDOWN" ]]; then
      mode="HTML"
      formatted="$(markdown_to_html "$chunk")"
    fi

    send_with_fallback "$mode" "$formatted" "$chunk"
    offset=$((offset + chunk_chars))
  done
}

markdown_to_html() {
  local input="$1"
  python3 - "$input" <<'PY'
import html
import re
import sys

text = sys.argv[1].replace("\r\n", "\n")
lines = text.split("\n")
out = []
in_code = False
code_lines = []

def inline_markup(value: str) -> str:
    v = html.escape(value, quote=False)
    v = re.sub(r"`([^`\n]+)`", r"<code>\1</code>", v)
    v = re.sub(r"\*\*([^*\n]+)\*\*", r"<b>\1</b>", v)
    v = re.sub(r"__([^_\n]+)__", r"<b>\1</b>", v)
    return v

for line in lines:
    stripped = line.strip()
    if stripped.startswith("```"):
        if in_code:
            out.append("<pre>" + html.escape("\n".join(code_lines), quote=False) + "</pre>")
            code_lines = []
            in_code = False
        else:
            in_code = True
            code_lines = []
        continue

    if in_code:
        code_lines.append(line)
        continue

    if stripped == "":
        out.append("")
        continue

    heading = re.match(r"^(#{1,6})\s+(.*)$", line)
    if heading:
        out.append("<b>" + inline_markup(heading.group(2).strip()) + "</b>")
        continue

    bullet = re.match(r"^\s*[-*]\s+(.*)$", line)
    if bullet:
        out.append("• " + inline_markup(bullet.group(1)))
        continue

    ordered = re.match(r"^\s*(\d+)\.\s+(.*)$", line)
    if ordered:
        out.append(ordered.group(1) + ". " + inline_markup(ordered.group(2)))
        continue

    out.append(inline_markup(line))

if in_code:
    out.append("<pre>" + html.escape("\n".join(code_lines), quote=False) + "</pre>")

sys.stdout.write("\n".join(out))
PY
}

send_task_complete_message() {
  local raw="$1"
  local mode="$2"
  local first_line kind session cwd topic timestamp reply_block body_source body_formatted

  first_line="$(printf '%s\n' "$raw" | head -n 1)"
  if [[ ! "$first_line" =~ ^\[Codex\ (Turn|Task)\ Complete\]$ ]]; then
    return 1
  fi

  kind="${BASH_REMATCH[1]}"
  session="$(printf '%s\n' "$raw" | sed -n 's/^session: //p' | head -n 1)"
  cwd="$(printf '%s\n' "$raw" | sed -n 's/^cwd: //p' | head -n 1)"
  topic="$(printf '%s\n' "$raw" | sed -n 's/^topic: //p' | head -n 1)"
  timestamp="$(printf '%s\n' "$raw" | sed -n 's/^time: //p' | head -n 1)"
  timestamp="$(format_timestamp_for_display "$timestamp")"
  reply_block="$(printf '%s\n' "$raw" | sed -n '/^reply: /,$p')"
  reply_block="${reply_block#reply: }"
  reply_block="$(sanitize_reply_text "$reply_block")"
  [[ -z "$reply_block" ]] && reply_block="<empty>"

  body_source="[Codex ${kind} Complete]"$'\n'
  body_source+="session: ${session}"$'\n'
  if [[ -n "$cwd" ]]; then
    body_source+="cwd: ${cwd}"$'\n'
  fi
  if [[ -n "$topic" ]]; then
    body_source+="topic: ${topic}"$'\n'
  fi
  body_source+="time: ${timestamp}"$'\n'
  if is_truthy "$TELEGRAM_FULL_REPLY"; then
    body_source+="reply: ${reply_block}"
  else
    if (( ${#reply_block} > 700 )); then
      body_source+="reply: ${reply_block:0:700}..."
    else
      body_source+="reply: ${reply_block}"
    fi
  fi

  case "${mode^^}" in
    HTML)
      body_formatted="$(format_html_message "$body_source")"
      ;;
    MARKDOWNV2)
      body_formatted="$(format_markdown_v2_message "$body_source")"
      ;;
    *)
      body_formatted="$body_source"
      ;;
  esac

  if (( ${#body_formatted} > 3900 )); then
    body_formatted="${body_formatted:0:3900}..."
  fi
  if (( ${#body_source} > 3900 )); then
    body_source="${body_source:0:3900}..."
  fi

  send_with_fallback "$mode" "$body_formatted" "$body_source"
}

MODE="${TELEGRAM_PARSE_MODE}"
case "${MODE^^}" in
  HTML)
    MODE="HTML"
    ;;
  MARKDOWNV2)
    MODE="MarkdownV2"
    ;;
  "")
    ;;
  *)
    # Keep user-specified parse mode as-is.
    ;;
esac

if send_task_complete_message "$RAW_MESSAGE" "$MODE"; then
  exit 0
fi

# Telegram hard limit is 4096 chars. Keep headroom for formatting.
if (( ${#MESSAGE} > 3200 )); then
  MESSAGE="${MESSAGE:0:3200}..."
fi
if (( ${#RAW_MESSAGE} > 3900 )); then
  RAW_MESSAGE="${RAW_MESSAGE:0:3900}..."
fi

case "${MODE^^}" in
  HTML)
    MESSAGE="$(format_html_message "$MESSAGE")"
    ;;
  MARKDOWNV2)
    MESSAGE="$(format_markdown_v2_message "$MESSAGE")"
    ;;
  "")
    ;;
  *)
    # Keep user-specified parse mode as-is.
    ;;
esac

if (( ${#MESSAGE} > 3900 )); then
  MESSAGE="${MESSAGE:0:3900}..."
fi

send_with_fallback "$MODE" "$MESSAGE" "$RAW_MESSAGE"
