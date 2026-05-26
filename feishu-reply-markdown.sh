#!/usr/bin/env bash
# Send a Feishu reply with Markdown formatting (converted to post by lark-cli).
set -euo pipefail

TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${TOOL_DIR}/lib/common.sh"

lark_oncall_load_env
lark_oncall_require_bin lark-cli

MESSAGE_ID=""
MARKDOWN_FILE=""
REPLY_IN_THREAD="${REPLY_IN_THREAD:-false}"
IDEMPOTENCY_KEY=""
DRY_RUN=false

usage() {
  cat <<'EOF'
Usage: feishu-reply-markdown.sh --message-id om_xxx (--file path | --stdin) [options]

Send a rich Markdown reply via lark-cli (rendered as Feishu post).

Options:
  --message-id <id>       Required. Target message om_xxx.
  --file <path>           Markdown file to send.
  --stdin                 Read Markdown from stdin instead of --file.
  --reply-in-thread       Reply inside the message thread (recommended for long traces).
  --idempotency-key <key> Idempotency key (default: at-mention-<message_id>).
  --dry-run               Print request without sending.
  -h, --help              Show this help.

Environment (from .env):
  REPLY_IN_THREAD=true    Default --reply-in-thread when flag not passed.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --message-id)
      MESSAGE_ID="$2"
      shift 2
      ;;
    --file)
      MARKDOWN_FILE="$2"
      shift 2
      ;;
    --stdin)
      MARKDOWN_FILE="-"
      shift
      ;;
    --reply-in-thread)
      REPLY_IN_THREAD=true
      shift
      ;;
    --idempotency-key)
      IDEMPOTENCY_KEY="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "${MESSAGE_ID}" ]]; then
  echo "--message-id is required" >&2
  exit 2
fi

if [[ -z "${MARKDOWN_FILE}" ]]; then
  echo "one of --file or --stdin is required" >&2
  exit 2
fi

if [[ "${MARKDOWN_FILE}" == "-" ]]; then
  BODY="$(cat)"
else
  if [[ ! -f "${MARKDOWN_FILE}" ]]; then
    echo "markdown file not found: ${MARKDOWN_FILE}" >&2
    exit 2
  fi
  BODY="$(<"${MARKDOWN_FILE}")"
fi

if [[ -z "${BODY//[[:space:]]/}" ]]; then
  echo "markdown body is empty" >&2
  exit 2
fi

if [[ -z "${IDEMPOTENCY_KEY}" ]]; then
  IDEMPOTENCY_KEY="at-mention-${MESSAGE_ID}"
fi

ARGS=(
  im +messages-reply
  --as user
  --message-id "${MESSAGE_ID}"
  --markdown "${BODY}"
  --idempotency-key "${IDEMPOTENCY_KEY}"
)

if [[ "${REPLY_IN_THREAD}" == "true" ]]; then
  ARGS+=(--reply-in-thread)
fi

if [[ "${DRY_RUN}" == "true" ]]; then
  ARGS+=(--dry-run)
fi

lark-cli "${ARGS[@]}"
