# Codex Telegram Notifier

Sends Telegram notifications for Codex usage in two ways:

1. `codex` process exit notifications via shell wrapper.
2. Codex task completion notifications by watching `~/.codex/sessions/*.jsonl`.

## Files

- `bin/telegram_notify.sh`: sends one Telegram message.
- `bin/codex_with_notify.sh`: wraps real `codex` and sends exit status.
- `bin/codex_session_watcher.py`: watches Codex session logs and sends completion notifications.
- `bin/start_watcher.sh` / `bin/stop_watcher.sh`: daemon controls.
- `bin/watcher_status.sh`: watcher health/status check.
- `bin/get_chat_id.sh`: helper to discover your Telegram chat id.
- `bin/telegram_codex_bridge.py`: optional Telegram -> `codex exec` bridge.
- `install.sh`: installs bash hook so `codex` uses wrapper and watcher auto-starts.

## Quick start

```bash
cd ~/projects/codex-telegram-notifier
cp .env.example .env
# fill TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID in .env
./install.sh
source ~/.bashrc
```

## Runbook (recommended order)

1. Set bot token and chat id in `.env`.
2. Send a one-time test:
   ```bash
   ~/projects/codex-telegram-notifier/bin/telegram_notify.sh "hello"
   ```
3. Start watcher:
   ```bash
   ~/projects/codex-telegram-notifier/bin/start_watcher.sh
   ```
4. Check watcher health:
   ```bash
   ~/projects/codex-telegram-notifier/bin/watcher_status.sh
   ```
5. Stop watcher when needed:
   ```bash
   ~/projects/codex-telegram-notifier/bin/stop_watcher.sh
   ```

Watcher runs as a background daemon (`nohup` + `setsid`), so you do not need to keep a terminal tab open.

## Telegram setup

1. In Telegram, create a bot with `@BotFather`.
2. Copy the bot token into `.env` as `TELEGRAM_BOT_TOKEN`.
3. Send `/start` to your bot from the account that should receive notifications.
4. Run:
   ```bash
   ~/projects/codex-telegram-notifier/bin/get_chat_id.sh
   ```
5. Copy the `chat_id` into `.env` as `TELEGRAM_CHAT_ID`.

## Manual test

```bash
~/projects/codex-telegram-notifier/bin/telegram_notify.sh "test from codex notifier"
```

## Notes

- The watcher starts with `--init-now`, so old session history is skipped on startup.
- Default notification trigger is `task_complete` (one message per finished Codex task).
- Set `TELEGRAM_NOTIFY_EVENT=agent_message` only if you want chatty intermediate notifications.
- Set `TELEGRAM_NOTIFY_REQUEST_USER_INPUT=true` to get alerts when Codex asks a question in Plan mode.
- Set `TELEGRAM_NOTIFY_PLAN_UPDATES=true` to get alerts when Codex updates plan steps (`update_plan`).
- Set `TELEGRAM_NOTIFY_ASSISTANT_PLAN_TEXT=true` to get alerts for assistant plan proposal text (for example `<proposed_plan>` blocks).
- If `task_complete.last_agent_message` is missing (`null`) in Plan mode, watcher falls back to the same turn's `assistant final_answer` text (for example `<proposed_plan>`), so it no longer sends `None`.
- Session watcher message format includes session id, inferred topic, timestamp, and reply body.
- Session watcher message now includes `cwd` (shown above topic in Telegram).
- `TELEGRAM_TASK_REPLY_MODE=full|preview` controls what watcher forwards for `task_complete`:
  - `full` (default): forward raw `last_agent_message` (keeps markdown/newlines)
  - `preview`: send compact single-line preview
- `topic` is human-friendly and can repeat; `session` is unique.
- Topic source is the first `user_message` found in that session file. (Codex UI session title is not currently present in session jsonl payload.)
- Watcher scans all files under `~/.codex/sessions`, but notifications are sent only when new matching events are appended.
- By default, messages are sent with Telegram `HTML` parse mode for rich formatting. You can change this with `TELEGRAM_PARSE_MODE` in `.env` (example: `MarkdownV2` or empty/plain text).
- For task-complete notifications, `TELEGRAM_FULL_REPLY=true|false` (default `true`) controls whether full reply is included.
- Full reply is sent as a single Telegram message (not split). If too long, it is truncated to fit Telegram limits.
- `TELEGRAM_REPLY_PARSE_MODE=auto|plain` (default `auto`): `auto` renders markdown-like reply text in Telegram HTML.
- `<proposed_plan>...</proposed_plan>` wrapper tags are stripped in reply display.
- `TELEGRAM_TIMEZONE=Asia/Seoul` (default `Asia/Seoul`) controls displayed time.
- If formatted sending fails for any reason, the notifier retries as plain text so alerts are not dropped.
- Use `TELEGRAM_TURN_ID_MODE` in `.env`:
  - `both` (default): show topic + session
  - `topic`: show topic only
  - `session`: show session only

## Optional: run Codex from Telegram

Use this only in a private chat and only with your own bot token.

1. Start the bridge:
   ```bash
   ~/projects/codex-telegram-notifier/bin/telegram_codex_bridge.py
   ```
2. In Telegram, send:
   ```text
   /codex summarize current repository status
   ```

Available commands in Telegram:

- `/help` or `/start`: show command help
- `/status`: show bridge runtime info
- `/id`: show allowed chat id
- `/codex <prompt>`: run `codex exec`

Security notes:

- The bridge only accepts messages from `TELEGRAM_CHAT_ID`.
- Anyone with access to that chat can run commands through Codex.
- Keep this disabled when not needed.

## Optional: auto-start on boot (systemd user service)

If you want watcher to survive reboot/login without manual start:

1. Create service file:
   ```bash
   mkdir -p ~/.config/systemd/user
   cat > ~/.config/systemd/user/codex-telegram-watcher.service <<'EOF'
   [Unit]
   Description=Codex Telegram Watcher
   After=default.target

   [Service]
   Type=simple
   Environment=CODEX_TELEGRAM_ENV=%h/projects/codex-telegram-notifier/.env
   ExecStart=%h/projects/codex-telegram-notifier/bin/codex_session_watcher.py --init-now
   Restart=always
   RestartSec=2

   [Install]
   WantedBy=default.target
   EOF
   ```
2. Enable and start:
   ```bash
   systemctl --user daemon-reload
   systemctl --user enable --now codex-telegram-watcher.service
   ```
3. Check status/log:
   ```bash
   systemctl --user status codex-telegram-watcher.service
   journalctl --user -u codex-telegram-watcher.service -n 100 --no-pager
   ```
