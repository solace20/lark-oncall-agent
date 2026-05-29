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

  AGENT_BACKEND="${AGENT_BACKEND:-cursor}"
  AGENT_MODE="${AGENT_MODE:-ask}"

  CURSOR_MODEL="${CURSOR_MODEL:-composer-2.5}"
  CURSOR_OUTPUT_FORMAT="${CURSOR_OUTPUT_FORMAT:-text}"
  CURSOR_FORCE="${CURSOR_FORCE:-false}"
  CURSOR_SANDBOX="${CURSOR_SANDBOX:-}"

  CLAUDE_MODEL="${CLAUDE_MODEL:-}"
  CLAUDE_OUTPUT_FORMAT="${CLAUDE_OUTPUT_FORMAT:-text}"
  CLAUDE_PERMISSION_MODE="${CLAUDE_PERMISSION_MODE:-plan}"
  CLAUDE_SKIP_PERMISSIONS="${CLAUDE_SKIP_PERMISSIONS:-false}"
  CLAUDE_ALLOWED_TOOLS="${CLAUDE_ALLOWED_TOOLS:-}"
  CLAUDE_DISALLOWED_TOOLS="${CLAUDE_DISALLOWED_TOOLS:-Edit,Write,NotebookEdit,MultiEdit}"

  LOGS_CLIENT="${LOGS_CLIENT:-}"
  export LOGS_CLIENT
}

lark_oncall_agent_label() {
  case "${AGENT_BACKEND}" in
    claude) printf 'Claude Code' ;;
    *) printf 'Cursor Agent CLI' ;;
  esac
}

lark_oncall_require_agent_backend() {
  case "${AGENT_BACKEND}" in
    claude)
      lark_oncall_require_bin claude
      lark_oncall_require_bin jq
      if ! claude auth status 2>/dev/null | jq -e '.loggedIn == true' >/dev/null; then
        echo "Claude Code not logged in. Run: claude auth login" >&2
        exit 1
      fi
      ;;
    cursor)
      lark_oncall_require_bin cursor
      if ! cursor agent --help >/dev/null 2>&1; then
        echo "cursor agent CLI not available. Upgrade Cursor CLI and verify: cursor agent --help" >&2
        exit 1
      fi
      local cursor_status
      cursor_status="$(cursor agent status 2>/dev/null || true)"
      if [[ "${cursor_status}" != *"Logged in"* ]]; then
        echo "Cursor Agent CLI not logged in. Run: cursor agent login" >&2
        exit 1
      fi
      ;;
    *)
      echo "unsupported AGENT_BACKEND=${AGENT_BACKEND} (use cursor or claude)" >&2
      exit 2
      ;;
  esac
}

lark_oncall_invoke_agent() {
  local prompt="$1"
  case "${AGENT_BACKEND}" in
    claude)
      local claude_args=(
        --print
        --output-format "${CLAUDE_OUTPUT_FORMAT}"
        --no-session-persistence
      )
      if [[ -n "${CLAUDE_MODEL}" ]]; then
        claude_args+=(--model "${CLAUDE_MODEL}")
      fi
      case "${AGENT_MODE}" in
        ask|plan)
          claude_args+=(--permission-mode plan)
          if [[ -n "${CLAUDE_DISALLOWED_TOOLS}" ]]; then
            claude_args+=(--disallowed-tools "${CLAUDE_DISALLOWED_TOOLS}")
          fi
          ;;
        agent|write|full)
          if [[ "${CLAUDE_SKIP_PERMISSIONS}" == "true" ]]; then
            claude_args+=(--dangerously-skip-permissions)
          elif [[ -n "${CLAUDE_PERMISSION_MODE}" ]]; then
            claude_args+=(--permission-mode "${CLAUDE_PERMISSION_MODE}")
          fi
          ;;
        *)
          echo "unsupported AGENT_MODE=${AGENT_MODE} (use ask, plan, or agent)" >&2
          return 2
          ;;
      esac
      if [[ -n "${CLAUDE_ALLOWED_TOOLS}" ]]; then
        claude_args+=(--allowed-tools "${CLAUDE_ALLOWED_TOOLS}")
      fi
      (
        cd "${WORKSPACE_ROOT}"
        claude "${claude_args[@]}" "${prompt}"
      )
      ;;
    cursor)
      local cursor_args=(
        agent
        --print
        --trust
        --workspace "${WORKSPACE_ROOT}"
        --output-format "${CURSOR_OUTPUT_FORMAT}"
      )
      if [[ -n "${CURSOR_MODEL}" ]]; then
        cursor_args+=(--model "${CURSOR_MODEL}")
      fi
      case "${AGENT_MODE}" in
        ask)
          cursor_args+=(--mode ask)
          ;;
        plan)
          cursor_args+=(--mode plan)
          ;;
        agent|write|full)
          if [[ -n "${CURSOR_SANDBOX}" ]]; then
            cursor_args+=(--sandbox "${CURSOR_SANDBOX}")
          fi
          if [[ "${CURSOR_FORCE}" == "true" ]]; then
            cursor_args+=(--force)
          fi
          ;;
        *)
          echo "unsupported AGENT_MODE=${AGENT_MODE} (use ask, plan, or agent)" >&2
          return 2
          ;;
      esac
      cursor "${cursor_args[@]}" "${prompt}"
      ;;
    *)
      echo "unsupported AGENT_BACKEND=${AGENT_BACKEND} (use cursor or claude)" >&2
      return 2
      ;;
  esac
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
