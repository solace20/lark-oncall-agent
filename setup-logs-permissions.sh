#!/usr/bin/env bash
# Merge optional logs CLI + lark-oncall-agent shell allow rules into agent CLI config.
# Supports Cursor (~/.cursor/cli-config.json) and Claude Code (~/.claude/settings.json).
# Idempotent — safe to re-run.
set -euo pipefail

TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${TOOL_DIR}/lib/common.sh"
lark_oncall_load_env

CURSOR_CLI_CONFIG="${CURSOR_CLI_CONFIG:-${HOME}/.cursor/cli-config.json}"
CLAUDE_SETTINGS="${CLAUDE_SETTINGS:-${HOME}/.claude/settings.json}"
SETUP_BACKEND="${SETUP_BACKEND:-${AGENT_BACKEND:-both}}"

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required" >&2
  exit 1
fi

NEW_ALLOW=(
  "Shell(codegraph *)"
  "Shell(${TOOL_DIR}/feishu-reply-markdown.sh *)"
  "Shell(lark-cli *)"
)

CLAUDE_ALLOW=(
  "Bash(codegraph *)"
  "Bash(${TOOL_DIR}/feishu-reply-markdown.sh *)"
  "Bash(lark-cli *)"
)

if [[ -n "${LOGS_CLIENT}" && -f "${LOGS_CLIENT}" ]]; then
  NEW_ALLOW+=(
    "Shell(python3 ${LOGS_CLIENT} *)"
    "Shell(PLATFORM_ENV=prod python3 ${LOGS_CLIENT} *)"
    "Shell(PLATFORM_ENV=production python3 ${LOGS_CLIENT} *)"
    "Shell(PLATFORM_ENV=test python3 ${LOGS_CLIENT} *)"
  )
  CLAUDE_ALLOW+=(
    "Bash(python3 ${LOGS_CLIENT} *)"
    "Bash(PLATFORM_ENV=prod python3 ${LOGS_CLIENT} *)"
    "Bash(PLATFORM_ENV=production python3 ${LOGS_CLIENT} *)"
    "Bash(PLATFORM_ENV=test python3 ${LOGS_CLIENT} *)"
  )
else
  echo "LOGS_CLIENT not set or file missing — skipping logs CLI allowlist entries."
  echo "Set LOGS_CLIENT in .env to your logs_client.py path, then re-run."
fi

merge_cursor_config() {
  local config="$1"
  mkdir -p "$(dirname "${config}")"
  if [[ ! -f "${config}" ]]; then
    echo '{"permissions":{"allow":[],"deny":[]},"version":1}' >"${config}"
  fi
  local tmp
  tmp="$(mktemp)"
  jq --argjson new "$(printf '%s\n' "${NEW_ALLOW[@]}" | jq -R . | jq -s .)" '
    .permissions.allow = ((.permissions.allow // []) + $new | unique)
  ' "${config}" >"${tmp}"
  mv "${tmp}" "${config}"
  echo "Updated ${config} permissions.allow."
  jq -r '.permissions.allow[]?' "${config}"
}

merge_claude_settings() {
  local settings="$1"
  mkdir -p "$(dirname "${settings}")"
  if [[ ! -f "${settings}" ]]; then
    echo '{"permissions":{"allow":[],"deny":[]}}' >"${settings}"
  fi
  local tmp
  tmp="$(mktemp)"
  jq --argjson new "$(printf '%s\n' "${CLAUDE_ALLOW[@]}" | jq -R . | jq -s .)" '
    .permissions.allow = ((.permissions.allow // []) + $new | unique)
  ' "${settings}" >"${tmp}"
  mv "${tmp}" "${settings}"
  echo "Updated ${settings} permissions.allow."
  jq -r '.permissions.allow[]?' "${settings}"
}

case "${SETUP_BACKEND}" in
  cursor)
    echo "== Cursor CLI =="
    merge_cursor_config "${CURSOR_CLI_CONFIG}"
    ;;
  claude)
    echo "== Claude Code =="
    merge_claude_settings "${CLAUDE_SETTINGS}"
    ;;
  both)
    echo "== Cursor CLI =="
    merge_cursor_config "${CURSOR_CLI_CONFIG}"
    echo ""
    echo "== Claude Code =="
    merge_claude_settings "${CLAUDE_SETTINGS}"
    ;;
  *)
    echo "unsupported SETUP_BACKEND=${SETUP_BACKEND} (use cursor, claude, or both)" >&2
    exit 2
    ;;
esac
