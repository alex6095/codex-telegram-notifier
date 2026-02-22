#!/usr/bin/env python3
"""Watch Codex session logs and send Telegram notifications for Codex events."""

from __future__ import annotations

import argparse
import json
import os
import signal
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Dict


STOP = False


@dataclass
class FileState:
    offset: int = 0
    topic: str = ""


def _signal_handler(signum, frame):  # type: ignore[no-untyped-def]
    del signum, frame
    global STOP
    STOP = True


def load_env_file(env_path: Path) -> None:
    if not env_path.exists():
        return
    for raw_line in env_path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip().strip('"').strip("'")
        os.environ.setdefault(key, value)


def load_state(path: Path) -> Dict[str, FileState]:
    if not path.exists():
        return {}
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return {}
    out: Dict[str, FileState] = {}
    for file_path, item in raw.items():
        if isinstance(item, dict):
            offset = int(item.get("offset", 0))
            topic = str(item.get("topic", "")).strip()
        else:
            offset = int(item)
            topic = ""
        out[file_path] = FileState(offset=max(0, offset), topic=topic)
    return out


def save_state(path: Path, state: Dict[str, FileState]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = {file_path: {"offset": st.offset, "topic": st.topic} for file_path, st in state.items()}
    path.write_text(json.dumps(payload, ensure_ascii=True, indent=2), encoding="utf-8")


def truncate_preview(text: str, limit: int) -> str:
    compact = " ".join(text.split())
    if len(compact) <= limit:
        return compact
    return compact[: limit - 3] + "..."


def build_session_topic(raw_message: str) -> str:
    text = str(raw_message).strip()
    if not text:
        return ""

    markers = [
        "## My request for Codex:",
        "My request for Codex:",
        "## My request:",
        "My request:",
    ]
    for marker in markers:
        if marker in text:
            tail = text.split(marker, 1)[1].strip()
            for line in tail.splitlines():
                line = line.strip().lstrip("- ").strip()
                if line and not line.startswith("```"):
                    return truncate_preview(line, 96)

    lines = [line.strip() for line in text.splitlines() if line.strip()]
    skip_prefixes = (
        "# Context from my IDE setup",
        "## Active file:",
        "## Open tabs:",
        "<environment_context>",
        "</environment_context>",
    )
    for line in reversed(lines):
        if line.startswith("```"):
            continue
        if line.startswith(skip_prefixes):
            continue
        if line.startswith("<") and line.endswith(">"):
            continue
        if line.startswith("#") and len(line) > 1:
            continue
        return truncate_preview(line, 96)

    return truncate_preview(" ".join(lines), 96)


def detect_topic_from_file(file_path: Path, max_lines: int = 300) -> str:
    try:
        with file_path.open("r", encoding="utf-8", errors="replace") as handle:
            for index, line in enumerate(handle):
                if index >= max_lines:
                    break
                try:
                    row = json.loads(line)
                except json.JSONDecodeError:
                    continue

                if row.get("type") != "event_msg":
                    continue

                payload = row.get("payload", {})
                if payload.get("type") != "user_message":
                    continue

                topic = build_session_topic(str(payload.get("message", "")))
                if topic:
                    return topic
    except Exception:
        return ""
    return ""


def send_notification(sender_script: Path, text: str) -> None:
    try:
        result = subprocess.run(
            [str(sender_script)],
            input=text,
            text=True,
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
        )
        if result.returncode != 0:
            err = (result.stderr or "").strip()
            if err:
                print(f"sender failed ({result.returncode}): {err}", file=sys.stderr)
            else:
                print(f"sender failed with return code {result.returncode}", file=sys.stderr)
        elif result.stderr:
            # Keep parse-mode fallback/debug messages visible in watcher logs.
            err = result.stderr.strip()
            if err:
                print(err, file=sys.stderr)
    except Exception:
        pass


def _parse_bool(value: str, default: bool = False) -> bool:
    if value is None:
        return default
    return str(value).strip().lower() in {"1", "true", "yes", "y", "on"}


def _short(text: str, limit: int) -> str:
    compact = " ".join(str(text).split())
    if len(compact) <= limit:
        return compact
    return compact[: limit - 3] + "..."


def build_request_user_input_text(payload: dict) -> str:
    if payload.get("type") != "function_call" or payload.get("name") != "request_user_input":
        return ""

    args_raw = payload.get("arguments")
    try:
        args = json.loads(args_raw) if isinstance(args_raw, str) else (args_raw or {})
    except Exception:
        args = {}

    questions = args.get("questions")
    if not isinstance(questions, list) or not questions:
        return "Codex is waiting for your input in Plan mode."

    lines = []
    lines.append(_short("Codex is waiting for your input in Plan mode.", 120))
    max_questions = 3
    for idx, q in enumerate(questions[:max_questions], 1):
        if not isinstance(q, dict):
            continue
        header = _short(q.get("header", f"Question {idx}"), 40)
        question = _short(q.get("question", ""), 260)
        if question:
            lines.append(f"{idx}. {header}: {question}")
        else:
            lines.append(f"{idx}. {header}")

        options = q.get("options")
        if isinstance(options, list) and options:
            max_options = 4
            for opt_idx, opt in enumerate(options[:max_options], 1):
                label = ""
                if isinstance(opt, dict):
                    label = _short(opt.get("label", ""), 120)
                if label:
                    lines.append(f"   - {opt_idx}) {label}")
            if len(options) > max_options:
                lines.append(f"   - ... ({len(options) - max_options} more)")

    if len(questions) > max_questions:
        lines.append(f"... ({len(questions) - max_questions} more questions)")

    return "\n".join(lines).strip()


def build_update_plan_text(payload: dict) -> str:
    if payload.get("type") != "function_call" or payload.get("name") != "update_plan":
        return ""

    args_raw = payload.get("arguments")
    try:
        args = json.loads(args_raw) if isinstance(args_raw, str) else (args_raw or {})
    except Exception:
        args = {}

    explanation = str(args.get("explanation", "")).strip()
    plan = args.get("plan")
    if not isinstance(plan, list) or not plan:
        if explanation:
            return f"Plan updated.\n{_short(explanation, 500)}"
        return "Plan updated."

    counts = {"completed": 0, "in_progress": 0, "pending": 0}
    lines = []
    lines.append("Plan updated.")
    if explanation:
        lines.append(_short(explanation, 500))

    max_steps = 8
    for idx, item in enumerate(plan[:max_steps], 1):
        if not isinstance(item, dict):
            continue
        status = str(item.get("status", "pending")).strip().lower() or "pending"
        step = _short(str(item.get("step", "")).strip(), 220)
        if status not in counts:
            counts[status] = 0
        counts[status] += 1
        if not step:
            continue
        lines.append(f"{idx}. [{status}] {step}")

    # Count statuses from full plan for accuracy.
    for item in plan[max_steps:]:
        if not isinstance(item, dict):
            continue
        status = str(item.get("status", "pending")).strip().lower() or "pending"
        if status not in counts:
            counts[status] = 0
        counts[status] += 1

    if len(plan) > max_steps:
        lines.append(f"... ({len(plan) - max_steps} more steps)")

    lines.append(
        f"Summary: completed={counts.get('completed', 0)}, "
        f"in_progress={counts.get('in_progress', 0)}, pending={counts.get('pending', 0)}"
    )
    return "\n".join(lines).strip()


def read_new_lines(file_path: Path, offset: int):
    with file_path.open("r", encoding="utf-8", errors="replace") as handle:
        handle.seek(offset)
        while True:
            line = handle.readline()
            if not line:
                break
            yield line
        new_offset = handle.tell()
    return new_offset


def process_file(
    file_path: Path,
    state: Dict[str, FileState],
    sender_script: Path,
    max_preview_chars: int,
    init_now: bool,
    notify_event: str,
    task_reply_mode: str,
    notify_request_user_input: bool,
    notify_plan_updates: bool,
) -> None:
    key = str(file_path)
    file_size = file_path.stat().st_size

    if key not in state:
        state[key] = FileState(offset=file_size if init_now else 0)

    if file_size < state[key].offset:
        state[key].offset = 0
    if not state[key].topic:
        state[key].topic = detect_topic_from_file(file_path) or file_path.stem

    current_offset = state[key].offset

    with file_path.open("r", encoding="utf-8", errors="replace") as handle:
        handle.seek(current_offset)
        while True:
            line = handle.readline()
            if not line:
                break

            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue

            row_type = str(row.get("type", ""))
            if row_type not in {"event_msg", "response_item"}:
                continue

            payload = row.get("payload", {})
            timestamp = str(row.get("timestamp", "unknown"))
            session_name = file_path.stem
            topic = state[key].topic or session_name

            if row_type == "event_msg":
                payload_type = str(payload.get("type", ""))
                message = ""

                if notify_event == "agent_message":
                    if payload_type != "agent_message":
                        continue
                    message = str(payload.get("message", "")).strip()
                else:
                    # Default behavior: one notification when a turn completes.
                    if payload_type != "task_complete":
                        continue
                    message = str(payload.get("last_agent_message", "")).strip()

                if not message:
                    continue

                if notify_event == "task_complete" and task_reply_mode == "full":
                    reply_text = message
                else:
                    reply_text = truncate_preview(message, max_preview_chars)

                alert = (
                    "[Codex Task Complete]\n"
                    f"session: {session_name}\n"
                    f"topic: {topic}\n"
                    f"time: {timestamp}\n"
                    f"reply: {reply_text}"
                )
                send_notification(sender_script, alert)
                continue

            # response_item path: detect plan-mode questions (request_user_input tool call).
            if notify_request_user_input:
                action_text = build_request_user_input_text(payload)
                if action_text:
                    alert = (
                        "[Codex Action Required]\n"
                        f"session: {session_name}\n"
                        f"topic: {topic}\n"
                        f"time: {timestamp}\n"
                        f"question: {action_text}"
                    )
                    send_notification(sender_script, alert)

            if notify_plan_updates:
                plan_text = build_update_plan_text(payload)
                if plan_text:
                    alert = (
                        "[Codex Plan Updated]\n"
                        f"session: {session_name}\n"
                        f"topic: {topic}\n"
                        f"time: {timestamp}\n"
                        f"plan: {plan_text}"
                    )
                    send_notification(sender_script, alert)

        state[key].offset = handle.tell()


def cleanup_removed_files(state: Dict[str, FileState], existing: set[str]) -> None:
    stale = [path for path in state if path not in existing]
    for path in stale:
        del state[path]


def main() -> int:
    script_dir = Path(__file__).resolve().parent
    project_dir = script_dir.parent
    env_path = Path(os.environ.get("CODEX_TELEGRAM_ENV", str(project_dir / ".env"))).expanduser()
    load_env_file(env_path)

    parser = argparse.ArgumentParser(description="Watch Codex sessions and send Telegram notifications.")
    parser.add_argument(
        "--sessions-dir",
        default=str(Path.home() / ".codex" / "sessions"),
        help="Directory containing Codex session jsonl files.",
    )
    parser.add_argument(
        "--state-file",
        default=str(Path.home() / ".local" / "state" / "codex-telegram-notifier" / "state.json"),
        help="State file to track read offsets.",
    )
    parser.add_argument("--poll-seconds", type=float, default=1.5, help="Polling interval.")
    parser.add_argument("--max-preview-chars", type=int, default=240, help="Max chars from model reply.")
    parser.add_argument(
        "--task-reply-mode",
        default=os.environ.get("TELEGRAM_TASK_REPLY_MODE", "full"),
        choices=["full", "preview"],
        help="How to include task_complete reply text (default: full).",
    )
    parser.add_argument(
        "--notify-event",
        default=os.environ.get("TELEGRAM_NOTIFY_EVENT", "task_complete"),
        choices=["task_complete", "agent_message"],
        help="Notification trigger event (default: task_complete).",
    )
    parser.add_argument(
        "--notify-request-user-input",
        default=os.environ.get("TELEGRAM_NOTIFY_REQUEST_USER_INPUT", "true"),
        help="Send notifications when Codex requests user input (Plan mode). true|false",
    )
    parser.add_argument(
        "--notify-plan-updates",
        default=os.environ.get("TELEGRAM_NOTIFY_PLAN_UPDATES", "true"),
        help="Send notifications when Codex updates plan steps (update_plan). true|false",
    )
    parser.add_argument(
        "--sender-script",
        default=str(Path(__file__).resolve().parent / "telegram_notify.sh"),
        help="Script used to send notifications.",
    )
    parser.add_argument(
        "--init-now",
        action="store_true",
        help="Start from current EOF for unseen files (skip old history).",
    )
    args = parser.parse_args()

    sessions_dir = Path(args.sessions_dir).expanduser().resolve()
    state_file = Path(args.state_file).expanduser().resolve()
    sender_script = Path(args.sender_script).expanduser().resolve()

    if not sessions_dir.exists():
        print(f"sessions directory not found: {sessions_dir}", file=sys.stderr)
        return 1

    if not sender_script.exists():
        print(f"sender script not found: {sender_script}", file=sys.stderr)
        return 1

    signal.signal(signal.SIGINT, _signal_handler)
    signal.signal(signal.SIGTERM, _signal_handler)

    state = load_state(state_file)

    while not STOP:
        try:
            files = sorted(sessions_dir.rglob("*.jsonl"))
            existing = {str(path) for path in files}

            for file_path in files:
                process_file(
                    file_path=file_path,
                    state=state,
                    sender_script=sender_script,
                    max_preview_chars=max(40, args.max_preview_chars),
                    init_now=args.init_now,
                    notify_event=args.notify_event,
                    task_reply_mode=args.task_reply_mode,
                    notify_request_user_input=_parse_bool(args.notify_request_user_input, default=True),
                    notify_plan_updates=_parse_bool(args.notify_plan_updates, default=True),
                )

            cleanup_removed_files(state, existing)
            save_state(state_file, state)

            # init-now should only affect newly discovered files during first loop
            args.init_now = False
            time.sleep(max(0.3, args.poll_seconds))
        except Exception as exc:  # keep daemon alive
            print(f"watcher error: {exc}", file=sys.stderr)
            time.sleep(2.0)

    save_state(state_file, state)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
