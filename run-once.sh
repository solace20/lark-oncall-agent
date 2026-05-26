#!/usr/bin/env bash
set -euo pipefail

TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${TOOL_DIR}/lib/common.sh"

lark_oncall_load_env
lark_oncall_require_bin cursor
lark_oncall_require_bin lark-cli
lark_oncall_require_bin jq
lark_oncall_prepare_chat_targets

mkdir -p "${LOG_DIR}"
touch "${HANDLED_FILE}"

if ! mkdir "${LOCK_DIR}" 2>/dev/null; then
  echo "$(date '+%Y-%m-%dT%H:%M:%S%z') another lark oncall agent run is active; skip"
  exit 0
fi

cleanup() {
  rmdir "${LOCK_DIR}" 2>/dev/null || true
}
trap cleanup EXIT

lark_oncall_compute_time_window
RUN_ID="$(date '+%Y%m%dT%H%M%S')"

LOGS_HINT=""
if [[ -n "${LOGS_CLIENT}" && -f "${LOGS_CLIENT}" ]]; then
  LOGS_HINT="logs_client=${LOGS_CLIENT} (optional; see prompt.md). Default production; test env PLATFORM_ENV=test; search window <3h."
fi

RUNTIME_PROMPT="$(cat <<EOF
You are a local Cursor CLI IM on-call agent. This run only handles Feishu group messages in the last ${WINDOW_MINUTES} minutes that @${MENTION_NAME}.

Runtime parameters:
- run_id: ${RUN_ID}
- workspace_root: ${WORKSPACE_ROOT}
- mention_name: ${MENTION_NAME}
- start_iso: ${START_ISO}
- end_iso: ${END_ISO}
- handled_file: ${HANDLED_FILE}
- target_chat_names_json: ${TARGET_CHAT_NAMES_JSON}
- target_chat_ids_json: ${TARGET_CHAT_IDS_JSON}
- reply_mode: ${REPLY_MODE}

CodeGraph: index at \${WORKSPACE_ROOT}/.codegraph/ covering the whole monorepo. For trace/call-chain questions prefer MCP codegraph_* or CLI \`codegraph query\` / \`codegraph context\`.

${LOGS_HINT:+Logs query: ${LOGS_HINT}}

Rich replies: for code traces / architecture / log query results use Markdown (headings, tables, code blocks); write to \${LOG_DIR}/replies/<message_id>.md then call feishu-reply-markdown.sh --reply-in-thread. Feishu does not render Mermaid — use ASCII diagrams. Short acks may use --text.

EOF
)"

FIXED_PROMPT="$(<"${PROMPT_FILE}")"
PROMPT="${RUNTIME_PROMPT}"$'\n'"${FIXED_PROMPT}"

CURSOR_ARGS=(
  agent
  --print
  --trust
  --workspace "${WORKSPACE_ROOT}"
  --output-format "${CURSOR_OUTPUT_FORMAT}"
)

if [[ -n "${CURSOR_MODEL}" ]]; then
  CURSOR_ARGS+=(--model "${CURSOR_MODEL}")
fi

if [[ -n "${CURSOR_SANDBOX}" ]]; then
  CURSOR_ARGS+=(--sandbox "${CURSOR_SANDBOX}")
fi

if [[ "${CURSOR_FORCE}" == "true" ]]; then
  CURSOR_ARGS+=(--force)
fi

cursor "${CURSOR_ARGS[@]}" "${PROMPT}"
