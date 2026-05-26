#!/usr/bin/env bash
# Merge optional logs CLI + lark-oncall-agent shell allow rules into Cursor CLI config.
# Idempotent — safe to re-run.
set -euo pipefail

TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${TOOL_DIR}/lib/common.sh"
lark_oncall_load_env

CLI_CONFIG="${CURSOR_CLI_CONFIG:-${HOME}/.cursor/cli-config.json}"
LOGS_CLIENT="${LOGS_CLIENT:-}"

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required" >&2
  exit 1
fi

mkdir -p "$(dirname "${CLI_CONFIG}")"
if [[ ! -f "${CLI_CONFIG}" ]]; then
  echo '{"permissions":{"allow":[],"deny":[]},"version":1}' >"${CLI_CONFIG}"
fi

NEW_ALLOW=(
  "Shell(codegraph *)"
  "Shell(${TOOL_DIR}/feishu-reply-markdown.sh *)"
  "Shell(lark-cli *)"
)

if [[ -n "${LOGS_CLIENT}" && -f "${LOGS_CLIENT}" ]]; then
  NEW_ALLOW+=(
    "Shell(python3 ${LOGS_CLIENT} *)"
    "Shell(PLATFORM_ENV=prod python3 ${LOGS_CLIENT} *)"
    "Shell(PLATFORM_ENV=production python3 ${LOGS_CLIENT} *)"
    "Shell(PLATFORM_ENV=test python3 ${LOGS_CLIENT} *)"
  )
else
  echo "LOGS_CLIENT not set or file missing — skipping logs CLI allowlist entries."
  echo "Set LOGS_CLIENT in .env to your logs_client.py path, then re-run."
fi

TMP="$(mktemp)"
jq --argjson new "$(printf '%s\n' "${NEW_ALLOW[@]}" | jq -R . | jq -s .)" '
  .permissions.allow = ((.permissions.allow // []) + $new | unique)
' "${CLI_CONFIG}" >"${TMP}"
mv "${TMP}" "${CLI_CONFIG}"

echo "Updated ${CLI_CONFIG} permissions.allow."
echo ""
echo "Current allow list:"
jq -r '.permissions.allow[]?' "${CLI_CONFIG}"
