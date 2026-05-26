#!/usr/bin/env bash
# Migrate an existing launchd instance to Plan B (poll-mentions.sh + SCAN_INTERVAL_SECONDS).
set -euo pipefail

TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_LABEL="${BASE_LABEL:-com.local.lark-oncall-agent}"
UID_VALUE="$(id -u)"

usage() {
  cat <<EOF
Usage: $0 <instance>

Example:
  $0 default
  $0 prod-oncall

Updates:
  - .env.<instance>: SCAN_INTERVAL_SECONDS (default 60), WINDOW_MINUTES (default 3), POLL_LOCK_DIR
  - LaunchAgent plist: poll-mentions.sh + StartInterval from env
  - reload launchd job
EOF
}

[[ $# -ge 1 ]] || { usage; exit 1; }

INSTANCE_ID="$1"
ENV_FILE="${TOOL_DIR}/.env.${INSTANCE_ID}"
PLIST_PATH="${HOME}/Library/LaunchAgents/${BASE_LABEL}.${INSTANCE_ID}.plist"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "config not found: ${ENV_FILE}" >&2
  exit 1
fi
if [[ ! -f "${PLIST_PATH}" ]]; then
  echo "LaunchAgent not found: ${PLIST_PATH}" >&2
  exit 1
fi

chmod +x "${TOOL_DIR}/poll-mentions.sh" "${TOOL_DIR}/run-once.sh"

set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a

SCAN_INTERVAL_SECONDS="${SCAN_INTERVAL_SECONDS:-60}"
WINDOW_MINUTES="${WINDOW_MINUTES:-3}"
LOCK_DIR="${LOCK_DIR:-/tmp/lark-oncall-agent-${INSTANCE_ID}.lock}"
POLL_LOCK_DIR="${POLL_LOCK_DIR:-${LOCK_DIR}.poll}"

upsert_env_var() {
  local key="$1"
  local value="$2"
  local file="$3"
  if grep -q "^${key}=" "${file}"; then
    if [[ "$(uname)" == "Darwin" ]]; then
      sed -i '' "s|^${key}=.*|${key}=${value}|" "${file}"
    else
      sed -i "s|^${key}=.*|${key}=${value}|" "${file}"
    fi
  else
    printf '%s=%s\n' "${key}" "${value}" >>"${file}"
  fi
}

upsert_env_var "SCAN_INTERVAL_SECONDS" "${SCAN_INTERVAL_SECONDS}" "${ENV_FILE}"
upsert_env_var "WINDOW_MINUTES" "${WINDOW_MINUTES}" "${ENV_FILE}"
upsert_env_var "POLL_LOCK_DIR" "${POLL_LOCK_DIR}" "${ENV_FILE}"

/usr/libexec/PlistBuddy -c "Set :ProgramArguments:0 ${TOOL_DIR}/poll-mentions.sh" "${PLIST_PATH}"
/usr/libexec/PlistBuddy -c "Set :StartInterval ${SCAN_INTERVAL_SECONDS}" "${PLIST_PATH}"

launchctl bootout "gui/${UID_VALUE}" "${PLIST_PATH}" 2>/dev/null || true
launchctl bootstrap "gui/${UID_VALUE}" "${PLIST_PATH}"
launchctl kickstart -k "gui/${UID_VALUE}/${BASE_LABEL}.${INSTANCE_ID}"

cat <<EOF
Upgraded to Plan B: ${BASE_LABEL}.${INSTANCE_ID}

  entry: poll-mentions.sh (every ${SCAN_INTERVAL_SECONDS}s)
  window: ${WINDOW_MINUTES} minutes
  config: ${ENV_FILE}
  plist: ${PLIST_PATH}

Manual poll:
  ENV_FILE=${ENV_FILE} ${TOOL_DIR}/poll-mentions.sh
EOF
