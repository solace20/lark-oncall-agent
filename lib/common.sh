# Shared helpers for lark-oncall-agent (source only).

lark_oncall_tool_dir() {
  if [[ -n "${TOOL_DIR:-}" ]]; then
    printf '%s' "${TOOL_DIR}"
    return
  fi
  cd "$(dirname "${BASH_SOURCE[1]}")/.." && pwd
}

lark_oncall_load_env() {
  TOOL_DIR="$(lark_oncall_tool_dir)"
  ENV_FILE="${ENV_FILE:-${TOOL_DIR}/.env}"
  DEFAULT_WORKSPACE_ROOT="$(cd "${TOOL_DIR}/../.." && pwd)"

  if [[ -f "${ENV_FILE}" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "${ENV_FILE}"
    set +a
  fi

  export PATH="${PATH:-/usr/bin:/bin:/usr/sbin:/sbin}:${HOME}/.local/bin:/usr/local/bin:/opt/homebrew/bin"

  WORKSPACE_ROOT="${WORKSPACE_ROOT:-${DEFAULT_WORKSPACE_ROOT}}"
  PROMPT_FILE="${PROMPT_FILE:-${TOOL_DIR}/prompt.md}"
  HANDLED_FILE="${HANDLED_FILE:-/tmp/lark-oncall-agent/handled_at_msg_ids.txt}"
  LOG_DIR="${LOG_DIR:-/tmp/lark-oncall-agent}"
  LOCK_DIR="${LOCK_DIR:-/tmp/lark-oncall-agent.lock}"
  POLL_LOCK_DIR="${POLL_LOCK_DIR:-${LOCK_DIR}.poll}"

  MENTION_NAME="${MENTION_NAME:-OnCall}"
  WINDOW_MINUTES="${WINDOW_MINUTES:-3}"
  SCAN_INTERVAL_SECONDS="${SCAN_INTERVAL_SECONDS:-60}"
  TARGET_CHAT_NAMES_JSON="${TARGET_CHAT_NAMES_JSON:-[\"Engineering On-call\",\"Platform Alerts\"]}"
  TARGET_CHAT_IDS_JSON="${TARGET_CHAT_IDS_JSON:-[]}"
  REPLY_MODE="${REPLY_MODE:-send}"

  CURSOR_MODEL="${CURSOR_MODEL:-composer-2.5}"
  CURSOR_OUTPUT_FORMAT="${CURSOR_OUTPUT_FORMAT:-text}"
  CURSOR_FORCE="${CURSOR_FORCE:-false}"
  CURSOR_SANDBOX="${CURSOR_SANDBOX:-}"

  LOGS_CLIENT="${LOGS_CLIENT:-}"
  export LOGS_CLIENT
}

lark_oncall_require_bin() {
  local bin="$1"
  if ! command -v "${bin}" >/dev/null 2>&1; then
    echo "missing required command: ${bin}" >&2
    exit 127
  fi
}

lark_oncall_validate_json_config() {
  if ! jq -e . >/dev/null <<<"${TARGET_CHAT_NAMES_JSON}"; then
    echo "TARGET_CHAT_NAMES_JSON is not valid JSON" >&2
    exit 2
  fi
  if ! jq -e . >/dev/null <<<"${TARGET_CHAT_IDS_JSON}"; then
    echo "TARGET_CHAT_IDS_JSON is not valid JSON" >&2
    exit 2
  fi
}

lark_oncall_resolve_chat_id_by_name() {
  local name="$1"
  lark-cli im +chat-search --as user --query "${name}" --disable-search-by-user --page-size 10 --format json 2>/dev/null \
    | jq -r --arg n "${name}" '(.data.chats // [])[] | select(.name == $n) | .chat_id' | head -1
}

lark_oncall_normalize_chat_ids_json() {
  jq -c '
    if length == 0 then []
    elif (.[0] | type) == "string" then map({name: "", chat_id: .})
    else .
    end
  ' <<<"${1}"
}

lark_oncall_merge_target_chat_ids() {
  local names_json="$1"
  local ids_json="$2"
  local resolved name chat_id
  resolved="$(lark_oncall_normalize_chat_ids_json "${ids_json}")"

  while IFS= read -r name; do
    [[ -z "${name}" ]] && continue
    if jq -e --arg n "${name}" 'any(.[]; .name == $n and (.chat_id | length) > 0)' <<<"${resolved}" >/dev/null; then
      continue
    fi
    chat_id="$(lark_oncall_resolve_chat_id_by_name "${name}")"
    if [[ -z "${chat_id}" ]]; then
      echo "$(date '+%Y-%m-%dT%H:%M:%S%z') WARN: chat-search miss for name=${name}" >&2
      continue
    fi
    resolved="$(jq -c --arg n "${name}" --arg c "${chat_id}" '. + [{name: $n, chat_id: $c}]' <<<"${resolved}")"
  done < <(jq -r '.[]' <<<"${names_json}")

  printf '%s' "${resolved}"
}

lark_oncall_prepare_chat_targets() {
  lark_oncall_validate_json_config
  TARGET_CHAT_IDS_JSON="$(lark_oncall_merge_target_chat_ids "${TARGET_CHAT_NAMES_JSON}" "${TARGET_CHAT_IDS_JSON}")"
}

lark_oncall_compute_time_window() {
  START_ISO="$(TZ=UTC date -v-"${WINDOW_MINUTES}"M '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || TZ=UTC date -d "-${WINDOW_MINUTES} minutes" '+%Y-%m-%dT%H:%M:%SZ')"
  END_ISO="$(TZ=UTC date '+%Y-%m-%dT%H:%M:%SZ')"
}

lark_oncall_handled_ids_json() {
  if [[ ! -f "${HANDLED_FILE}" ]]; then
    printf '[]'
    return
  fi
  jq -R -s 'split("\n") | map(select(length > 0))' <"${HANDLED_FILE}"
}

lark_oncall_list_pending_mention_ids() {
  local chat_id="$1"
  local raw handled_json
  handled_json="$(lark_oncall_handled_ids_json)"
  raw="$(lark-cli im +chat-messages-list --as user --chat-id "${chat_id}" \
    --start "${START_ISO}" --end "${END_ISO}" --sort asc --page-size 50 --format json 2>/dev/null || true)"
  if [[ -z "${raw}" ]]; then
    return 0
  fi
  jq -r --arg mention "${MENTION_NAME}" --argjson handled "${handled_json}" '
    (.data.messages // .messages // .data.items // .items // [])[]
    | select((.deleted // false | not))
    | select(
        (.mentions // [])
        | any(
            .[];
            (((.name // "") | tostring) + " " + ((.key // "") | tostring) + " " + ((.id // "") | tostring))
            | contains($mention)
          )
      )
    | select(.message_id as $id | ($handled | index($id)) | not)
    | .message_id
  ' <<<"${raw}"
}
