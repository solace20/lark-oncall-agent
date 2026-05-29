#!/usr/bin/env bash
set -euo pipefail

TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_LABEL="${BASE_LABEL:-com.local.lark-oncall-agent}"
UID_VALUE="$(id -u)"

require_bin() {
  local bin="$1"
  if ! command -v "${bin}" >/dev/null 2>&1; then
    echo "missing dependency: ${bin}" >&2
    return 1
  fi
}

prompt_with_default() {
  local prompt="$1"
  local default_value="$2"
  local answer
  read -r -p "${prompt} [${default_value}]: " answer
  if [[ -z "${answer}" ]]; then
    printf '%s' "${default_value}"
  else
    printf '%s' "${answer}"
  fi
}

json_array_from_hash_list() {
  local raw="$1"
  printf '%s' "${raw}" | jq -Rc 'split("#") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))'
}

shell_quote() {
  printf '%q' "$1"
}

validate_instance_id() {
  local value="$1"
  if [[ ! "${value}" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "instance id may only contain letters, digits, dot, underscore, hyphen" >&2
    return 1
  fi
}

echo "== Checking dependencies =="
require_bin lark-cli
require_bin jq

AGENT_BACKEND="$(prompt_with_default "Agent backend (cursor or claude)" "cursor")"
case "${AGENT_BACKEND}" in
  cursor|claude) ;;
  *)
    echo "AGENT_BACKEND must be cursor or claude" >&2
    exit 1
    ;;
esac

# Validate selected agent CLI before continuing install prompts.
# shellcheck disable=SC1091
source "${TOOL_DIR}/lib/common.sh"
export AGENT_BACKEND
lark_oncall_require_agent_backend

echo "Dependencies OK (${AGENT_BACKEND})."
echo

INSTANCE_ID="$(prompt_with_default "Instance name (for multiple jobs on one Mac)" "default")"
validate_instance_id "${INSTANCE_ID}"

LABEL="${BASE_LABEL}.${INSTANCE_ID}"
ENV_FILE="${TOOL_DIR}/.env.${INSTANCE_ID}"
PLIST_PATH="${HOME}/Library/LaunchAgents/${LABEL}.plist"
LOG_DIR="/tmp/lark-oncall-agent/${INSTANCE_ID}"
HANDLED_FILE="${LOG_DIR}/handled_at_msg_ids.txt"
LOCK_DIR="/tmp/lark-oncall-agent-${INSTANCE_ID}.lock"

WORKSPACE_ROOT_INPUT="$(prompt_with_default "Workspace root (code the agent should read)" "$(pwd)")"
WORKSPACE_ROOT="$(cd "${WORKSPACE_ROOT_INPUT}" && pwd)"
MENTION_NAME="$(prompt_with_default "Your display name for @ matching" "OnCall")"
GROUP_NAMES_INPUT="$(prompt_with_default "Target chat names (#-separated)" "Engineering On-call#Platform Alerts")"
TARGET_CHAT_NAMES_JSON="$(json_array_from_hash_list "${GROUP_NAMES_INPUT}")"
SCAN_INTERVAL_SECONDS="$(prompt_with_default "Light poll interval seconds (agent only on @ hit)" "60")"
WINDOW_MINUTES="$(prompt_with_default "Message lookback minutes (~2-3x interval)" "3")"

if [[ "${TARGET_CHAT_NAMES_JSON}" == "[]" ]]; then
  echo "At least one chat name is required." >&2
  exit 1
fi

WORKSPACE_ROOT_ENV="$(shell_quote "${WORKSPACE_ROOT}")"
MENTION_NAME_ENV="$(shell_quote "${MENTION_NAME}")"
LOG_DIR_ENV="$(shell_quote "${LOG_DIR}")"
HANDLED_FILE_ENV="$(shell_quote "${HANDLED_FILE}")"
LOCK_DIR_ENV="$(shell_quote "${LOCK_DIR}")"
TARGET_CHAT_NAMES_JSON_ENV="$(shell_quote "${TARGET_CHAT_NAMES_JSON}")"

echo
echo "Install configuration:"
echo "  backend: ${AGENT_BACKEND}"
echo "  instance: ${INSTANCE_ID}"
echo "  label: ${LABEL}"
echo "  workspace: ${WORKSPACE_ROOT}"
echo "  mention: ${MENTION_NAME}"
echo "  chats: ${TARGET_CHAT_NAMES_JSON}"
echo

mkdir -p "${LOG_DIR}" "${HOME}/Library/LaunchAgents"
chmod +x "${TOOL_DIR}/run-once.sh" "${TOOL_DIR}/poll-mentions.sh"

cat > "${ENV_FILE}" <<EOF
# Local runtime config for ${INSTANCE_ID}. Do not put tokens here; lark-cli stores auth separately.

WORKSPACE_ROOT=${WORKSPACE_ROOT_ENV}
MENTION_NAME=${MENTION_NAME_ENV}
WINDOW_MINUTES=${WINDOW_MINUTES}
SCAN_INTERVAL_SECONDS=${SCAN_INTERVAL_SECONDS}
HANDLED_FILE=${HANDLED_FILE_ENV}
LOG_DIR=${LOG_DIR_ENV}
LOCK_DIR=${LOCK_DIR_ENV}
POLL_LOCK_DIR=${LOCK_DIR_ENV}.poll
REPLY_MODE=send
REPLY_IN_THREAD=true

TARGET_CHAT_IDS_JSON='[]'
TARGET_CHAT_NAMES_JSON=${TARGET_CHAT_NAMES_JSON_ENV}

AGENT_BACKEND=${AGENT_BACKEND}
AGENT_MODE=ask

CURSOR_MODEL=composer-2.5
CURSOR_OUTPUT_FORMAT=text
CURSOR_FORCE=false
CURSOR_SANDBOX=

CLAUDE_MODEL=
CLAUDE_OUTPUT_FORMAT=text
CLAUDE_PERMISSION_MODE=plan
CLAUDE_SKIP_PERMISSIONS=false
CLAUDE_DISALLOWED_TOOLS=Edit,Write,NotebookEdit,MultiEdit

# Optional logs CLI (set LOGS_CLIENT after installing your logs skill)
# LOGS_CLIENT=
EOF

cat > "${PLIST_PATH}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LABEL}</string>

  <key>ProgramArguments</key>
  <array>
    <string>${TOOL_DIR}/poll-mentions.sh</string>
  </array>

  <key>WorkingDirectory</key>
  <string>${WORKSPACE_ROOT}</string>

  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key>
    <string>${HOME}</string>
    <key>PATH</key>
    <string>${HOME}/.local/bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>SHELL</key>
    <string>/bin/zsh</string>
    <key>ENV_FILE</key>
    <string>${ENV_FILE}</string>
  </dict>

  <key>StartInterval</key>
  <integer>${SCAN_INTERVAL_SECONDS}</integer>

  <key>RunAtLoad</key>
  <true/>

  <key>StandardOutPath</key>
  <string>${LOG_DIR}/launchd.log</string>
  <key>StandardErrorPath</key>
  <string>${LOG_DIR}/launchd.err.log</string>
</dict>
</plist>
EOF

launchctl bootout "gui/${UID_VALUE}" "${PLIST_PATH}" 2>/dev/null || true
launchctl bootstrap "gui/${UID_VALUE}" "${PLIST_PATH}"
launchctl kickstart -k "gui/${UID_VALUE}/${LABEL}"

cat <<EOF
Installed ${LABEL}

Config:
  ${ENV_FILE}

LaunchAgent:
  ${PLIST_PATH}

Logs:
  ${LOG_DIR}/launchd.log
  ${LOG_DIR}/launchd.err.log

Manage:
  ${TOOL_DIR}/manage-launchd.sh list
  ${TOOL_DIR}/manage-launchd.sh status ${INSTANCE_ID}
  ${TOOL_DIR}/manage-launchd.sh remove ${INSTANCE_ID}
EOF
