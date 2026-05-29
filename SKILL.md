---
name: lark-oncall-agent
description: >-
  Feishu @ on-call agent: macOS launchd polls target chats via lark-cli; on @mention hits,
  invokes Cursor Agent CLI or Claude Code to analyze and reply as the user. Install/manage launchd,
  configure .env, manual run-once, or follow prompt.md when invoked by run-once.sh.
---

# Feishu @ on-call agent

Tooling directory: clone or copy this repo (e.g. `tools/lark-oncall-agent/`). Scripts and `prompt.md` live here.

## When to use

- Install, enable, stop, or uninstall Feishu @ on-call via launchd
- Configure target chats, mention alias, scan window, `dry-run`
- Switch agent backend between Cursor Agent CLI and Claude Code
- When `run-once.sh` invokes you: follow [prompt.md](prompt.md)

All `lark-cli im` commands **must** use `--as user`. See `lark-im` skill for Feishu API details.

## Prerequisites

Choose one agent backend via `AGENT_BACKEND` in `.env` (`cursor` or `claude`).

### Cursor backend (default)

```bash
cursor agent --help
cursor agent login && cursor agent status   # must be Logged in
```

### Claude Code backend

```bash
claude --help
claude auth login && claude auth status     # loggedIn must be true
```

### Common

```bash
lark-cli --help
jq --version
python3 --version   # only if using optional LOGS_CLIENT
```

### Optional logs integration

If you have a `logs_client.py` CLI for your observability platform:

```bash
chmod +x tools/lark-oncall-agent/setup-logs-permissions.sh
LOGS_CLIENT=/path/to/logs_client.py tools/lark-oncall-agent/setup-logs-permissions.sh
```

Set `LOGS_CLIENT` in `.env`. For unattended runs with logs access:

- **ask/plan mode (default)**: read-only; no source edits. Cursor uses `--mode ask`; Claude uses `--permission-mode plan` and blocks Edit/Write tools.
- **agent mode** (opt-in): set `AGENT_MODE=agent`. Cursor may use `CURSOR_FORCE=true`; Claude may use `CLAUDE_SKIP_PERMISSIONS=true` if needed.

Feishu user auth (one-time):

```bash
lark-cli auth login --scope "im:chat:read im:message im:message.send_as_user im:message.group_msg:get_as_user im:message.p2p_msg:get_as_user contact:user.base:readonly"
```

## Install launchd (interactive)

From the **workspace root** where the agent should read code:

```bash
cd /path/to/project
chmod +x tools/lark-oncall-agent/*.sh
tools/lark-oncall-agent/install-launchd.sh
```

The installer asks: agent backend (`cursor` / `claude`), instance name, workspace root, `MENTION_NAME`, target chat names (`#`-separated), poll interval (default 60s). It writes `.env.<instance>` and a LaunchAgent that runs `poll-mentions.sh` — the agent starts only when an unhandled @mention is found.

## Common commands

| Action | Command |
|--------|---------|
| Light poll | `ENV_FILE=tools/lark-oncall-agent/.env.default tools/lark-oncall-agent/poll-mentions.sh` |
| Full agent run | `ENV_FILE=... tools/lark-oncall-agent/run-once.sh` |
| List instances | `tools/lark-oncall-agent/manage-launchd.sh list` |
| Restart | `manage-launchd.sh kick <instance>` |
| Logs | `manage-launchd.sh logs <instance>` |
| Remove | `manage-launchd.sh remove <instance>` |

First validation: set `REPLY_MODE=dry-run` in `.env`.

## Configuration

Copy [env.example](env.example) to `.env.<instance>`:

- `AGENT_BACKEND` — `cursor` (default) or `claude`
- `AGENT_MODE` — `ask` (default, read-only), `plan`, or `agent` (allows writes)
- `WORKSPACE_ROOT` — agent workspace root
- `MENTION_NAME` — name matched in @mentions (default `OnCall`)
- `TARGET_CHAT_NAMES_JSON` / `TARGET_CHAT_IDS_JSON` — monitored chats
- `SCAN_INTERVAL_SECONDS` — launchd poll interval (default 60)
- `WINDOW_MINUTES` — lookback window (default 3; ~2–3× interval)
- `HANDLED_FILE` — idempotency file per instance
- `LOGS_CLIENT` — optional path to logs CLI script
- `CURSOR_*` — Cursor backend settings
- `CLAUDE_*` — Claude Code backend settings

## When invoked by run-once

1. Read runtime parameters (`workspace_root`, `mention_name`, window, `reply_mode`, …)
2. Follow [prompt.md](prompt.md) hard constraints and six steps
3. No `git push`/merge/reset/checkout; no file deletes; destructive ops → risk reply only
4. Rich replies: Markdown + `feishu-reply-markdown.sh` (see prompt.md)

See [README.md](README.md) for full documentation.
