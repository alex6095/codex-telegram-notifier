#!/usr/bin/env python3
"""Run codex exec from Telegram commands."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from pathlib import Path
from urllib.parse import urlencode
from urllib.request import Request, urlopen


def is_truthy(value: str) -> bool:
    return value.strip().lower() in {"1", "true", "yes", "on"}


def load_env(env_path: Path) -> None:
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


def tg_call(token: str, method: str, params: dict):
    base = f"https://api.telegram.org/bot{token}/{method}"
    data = urlencode(params).encode("utf-8")
    req = Request(base, data=data, method="POST")
    with urlopen(req, timeout=30) as res:
        body = res.read().decode("utf-8", "replace")
    return json.loads(body)


def tg_send(token: str, chat_id: str, text: str) -> None:
    if len(text) > 3800:
        text = text[:3800] + "..."
    tg_call(token, "sendMessage", {"chat_id": chat_id, "text": text, "disable_web_page_preview": "true"})


def resolve_real_codex(project_dir: Path) -> str:
    configured = os.environ.get("CODEX_REAL_BIN", "").strip()
    if configured and Path(configured).exists():
        return configured

    path_file = project_dir / ".codex-real-path"
    if path_file.exists():
        saved = path_file.read_text(encoding="utf-8").strip()
        if saved and Path(saved).exists():
            return saved

    found = subprocess.run(["bash", "-lc", "command -v codex"], check=False, capture_output=True, text=True)
    candidate = found.stdout.strip()
    if candidate:
        return candidate
    raise RuntimeError("Unable to resolve codex binary")


def parse_command(text: str) -> tuple[str, str]:
    stripped = text.strip()
    if not stripped:
        return "", ""
    if not stripped.startswith("/"):
        return "", stripped

    parts = stripped.split(maxsplit=1)
    command = parts[0].split("@", 1)[0].lower()
    argument = parts[1].strip() if len(parts) > 1 else ""
    return command, argument


def help_text() -> str:
    return (
        "Codex Telegram Bridge commands\n"
        "/help - show this message\n"
        "/start - show this message\n"
        "/status - bridge status\n"
        "/id - show current chat id\n"
        "/codex <prompt> - run codex exec\n\n"
        "Examples:\n"
        "/codex summarize current repository status\n"
        "/codex fix failing tests in backend\n"
    )


def run_codex_exec(codex_bin: str, prompt: str, timeout_seconds: int) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [codex_bin, "exec", prompt],
        check=False,
        capture_output=True,
        text=True,
        timeout=timeout_seconds,
    )


def main() -> int:
    script_dir = Path(__file__).resolve().parent
    project_dir = script_dir.parent
    env_path = Path(os.environ.get("CODEX_TELEGRAM_ENV", str(project_dir / ".env"))).expanduser()
    load_env(env_path)

    token = os.environ.get("TELEGRAM_BOT_TOKEN", "").strip()
    allowed_chat = os.environ.get("TELEGRAM_CHAT_ID", "").strip()
    if not token or not allowed_chat:
        print("TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID are required", file=sys.stderr)
        return 1

    timeout_seconds = int(os.environ.get("TELEGRAM_BRIDGE_TIMEOUT_SECONDS", "1800").strip() or "1800")
    plain_as_codex = is_truthy(os.environ.get("TELEGRAM_BRIDGE_PLAIN_TEXT_AS_CODEX", "false"))

    codex_bin = resolve_real_codex(project_dir)
    print(
        f"bridge started; codex={codex_bin}; allowed_chat={allowed_chat}; "
        f"timeout={timeout_seconds}s; plain_as_codex={plain_as_codex}"
    )

    offset = None
    while True:
        try:
            params = {"timeout": 25}
            if offset is not None:
                params["offset"] = str(offset)

            updates = tg_call(token, "getUpdates", params)
            for item in updates.get("result", []):
                update_id = int(item.get("update_id", 0))
                offset = update_id + 1

                message = item.get("message") or {}
                chat = message.get("chat") or {}
                chat_id = str(chat.get("id", ""))
                text = str(message.get("text", ""))

                if chat_id != allowed_chat:
                    continue

                command, argument = parse_command(text)
                if not command and plain_as_codex and argument:
                    command = "/codex"
                if not command:
                    continue

                if command in {"/start", "/help"}:
                    tg_send(token, allowed_chat, help_text())
                    continue

                if command == "/status":
                    tg_send(
                        token,
                        allowed_chat,
                        (
                            "[bridge] status: running\n"
                            f"codex: {codex_bin}\n"
                            f"allowed_chat: {allowed_chat}\n"
                            f"timeout_seconds: {timeout_seconds}\n"
                            f"plain_text_as_codex: {plain_as_codex}"
                        ),
                    )
                    continue

                if command == "/id":
                    tg_send(token, allowed_chat, f"[bridge] chat_id: {allowed_chat}")
                    continue

                if command != "/codex":
                    tg_send(token, allowed_chat, f"[bridge] unknown command: {command}\nUse /help")
                    continue

                prompt = argument.strip()
                if not prompt:
                    tg_send(
                        token,
                        allowed_chat,
                        "[bridge] usage: /codex <prompt>\nExample: /codex summarize current repository status",
                    )
                    continue

                tg_send(token, allowed_chat, "[bridge] running codex exec...")
                run = run_codex_exec(codex_bin=codex_bin, prompt=prompt, timeout_seconds=timeout_seconds)

                output = (run.stdout or "") + ("\n" + run.stderr if run.stderr else "")
                output = output.strip() or "<empty output>"
                reply = (
                    f"[bridge] done (exit={run.returncode})\n"
                    f"prompt: {prompt[:120]}\n"
                    f"output:\n{output[:3000]}"
                )
                tg_send(token, allowed_chat, reply)
        except subprocess.TimeoutExpired:
            tg_send(token, allowed_chat, "[bridge] codex exec timed out")
        except Exception as exc:
            print(f"bridge error: {exc}", file=sys.stderr)
            time.sleep(2)


if __name__ == "__main__":
    raise SystemExit(main())
