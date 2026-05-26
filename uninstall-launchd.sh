#!/usr/bin/env bash
set -euo pipefail

TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $# -eq 0 ]]; then
  echo "Specify instance name or label. Installed:"
  "${TOOL_DIR}/manage-launchd.sh" list
  exit 1
fi

"${TOOL_DIR}/manage-launchd.sh" remove "$@"
