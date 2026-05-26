#!/usr/bin/env bash
# Lightweight poll: lark-cli + jq only. Invokes run-once.sh when @mentions are pending.
set -euo pipefail

TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${TOOL_DIR}/lib/common.sh"

lark_oncall_load_env
lark_oncall_require_bin lark-cli
lark_oncall_require_bin jq
lark_oncall_prepare_chat_targets
lark_oncall_compute_time_window

mkdir -p "${LOG_DIR}"
touch "${HANDLED_FILE}"

if ! mkdir "${POLL_LOCK_DIR}" 2>/dev/null; then
  echo "$(date '+%Y-%m-%dT%H:%M:%S%z') poll: another poll is active; skip"
  exit 0
fi

poll_cleanup() {
  rmdir "${POLL_LOCK_DIR}" 2>/dev/null || true
}
trap poll_cleanup EXIT

POLL_ID="$(date '+%Y%m%dT%H%M%S')"
PENDING_IDS=()
CHAT_COUNT="$(jq 'length' <<<"${TARGET_CHAT_IDS_JSON}")"

if [[ "${CHAT_COUNT}" == "0" ]]; then
  echo "$(date '+%Y-%m-%dT%H:%M:%S%z') poll=${POLL_ID} no chat targets configured"
  exit 0
fi

while IFS=$'\t' read -r chat_name chat_id; do
  [[ -z "${chat_id}" ]] && continue
  while IFS= read -r mid; do
    [[ -z "${mid}" ]] && continue
    PENDING_IDS+=("${mid}")
    echo "$(date '+%Y-%m-%dT%H:%M:%S%z') poll=${POLL_ID} pending chat=${chat_name:-unknown} message_id=${mid}"
  done < <(lark_oncall_list_pending_mention_ids "${chat_id}")
done < <(jq -r '.[] | "\(.name // "")\t\(.chat_id)"' <<<"${TARGET_CHAT_IDS_JSON}")

if [[ "${#PENDING_IDS[@]}" -eq 0 ]]; then
  echo "$(date '+%Y-%m-%dT%H:%M:%S%z') poll=${POLL_ID} no-op window=${START_ISO}..${END_ISO} chats=${CHAT_COUNT}"
  exit 0
fi

echo "$(date '+%Y-%m-%dT%H:%M:%S%z') poll=${POLL_ID} hit count=${#PENDING_IDS[@]} -> run-once.sh"
trap - EXIT
poll_cleanup
exec env ENV_FILE="${ENV_FILE}" "${TOOL_DIR}/run-once.sh"
