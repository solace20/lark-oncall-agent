#!/usr/bin/env bash
set -euo pipefail

BASE_LABEL="${BASE_LABEL:-com.local.lark-oncall-agent}"
UID_VALUE="$(id -u)"
LAUNCH_AGENTS_DIR="${HOME}/Library/LaunchAgents"

usage() {
  cat <<EOF
Usage:
  $0 list
  $0 status <instance|label>
  $0 start <instance|label>
  $0 stop <instance|label>
  $0 kick <instance|label>
  $0 remove <instance|label> [-f]
  $0 logs <instance|label>
  $0 errors <instance|label>

Examples:
  $0 list
  $0 status default
  $0 remove work -f
EOF
}

label_from_arg() {
  local value="$1"
  if [[ "${value}" == "${BASE_LABEL}" || "${value}" == "${BASE_LABEL}."* ]]; then
    printf '%s' "${value}"
  else
    printf '%s.%s' "${BASE_LABEL}" "${value}"
  fi
}

plist_for_label() {
  local label="$1"
  printf '%s/%s.plist' "${LAUNCH_AGENTS_DIR}" "${label}"
}

ensure_plist_exists() {
  local label="$1"
  local plist
  plist="$(plist_for_label "${label}")"
  if [[ ! -f "${plist}" ]]; then
    echo "not installed: ${label}" >&2
    exit 1
  fi
}

plist_field() {
  local label="$1"
  local field="$2"
  local plist
  plist="$(plist_for_label "${label}")"
  if [[ "${field}" == env.* ]]; then
    /usr/libexec/PlistBuddy -c "Print :EnvironmentVariables:${field#env.}" "${plist}" 2>/dev/null || true
  else
    /usr/libexec/PlistBuddy -c "Print :${field}" "${plist}" 2>/dev/null || true
  fi
}

list_instances() {
  local plist label instance env_file stdout workdir
  shopt -s nullglob
  for plist in "${LAUNCH_AGENTS_DIR}/${BASE_LABEL}"*.plist; do
    label="$(/usr/libexec/PlistBuddy -c "Print :Label" "${plist}" 2>/dev/null || true)"
    if [[ -z "${label}" ]]; then
      continue
    fi
    if [[ "${label}" != "${BASE_LABEL}" && "${label}" != "${BASE_LABEL}."* ]]; then
      continue
    fi
    if [[ "${label}" == "${BASE_LABEL}" ]]; then
      instance="legacy"
    else
      instance="${label#${BASE_LABEL}.}"
    fi
    env_file="$(/usr/libexec/PlistBuddy -c "Print :EnvironmentVariables:ENV_FILE" "${plist}" 2>/dev/null || true)"
    stdout="$(/usr/libexec/PlistBuddy -c "Print :StandardOutPath" "${plist}" 2>/dev/null || true)"
    workdir="$(/usr/libexec/PlistBuddy -c "Print :WorkingDirectory" "${plist}" 2>/dev/null || true)"
    printf '%s|%s|%s|%s|%s|%s\n' "${instance}" "${label}" "${plist}" "${env_file}" "${stdout}" "${workdir}"
  done
}

cmd_list() {
  printf '%-18s %-42s %-8s %s\n' "INSTANCE" "LABEL" "LOADED" "WORKDIR"
  list_instances | while IFS='|' read -r instance label plist env_file stdout workdir; do
    local loaded="no"
    if launchctl print "gui/${UID_VALUE}/${label}" >/dev/null 2>&1; then
      loaded="yes"
    fi
    printf '%-18s %-42s %-8s %s\n' "${instance}" "${label}" "${loaded}" "${workdir}"
  done
}

cmd_status() {
  local label="$1"
  ensure_plist_exists "${label}"
  launchctl print "gui/${UID_VALUE}/${label}"
}

cmd_start() {
  local label="$1"
  local plist
  ensure_plist_exists "${label}"
  plist="$(plist_for_label "${label}")"
  launchctl bootstrap "gui/${UID_VALUE}" "${plist}" 2>/dev/null || true
  launchctl kickstart -k "gui/${UID_VALUE}/${label}"
}

cmd_stop() {
  local label="$1"
  local plist
  ensure_plist_exists "${label}"
  plist="$(plist_for_label "${label}")"
  launchctl bootout "gui/${UID_VALUE}" "${plist}" 2>/dev/null || true
}

cmd_remove() {
  local label="$1"
  local force="${2:-}"
  local plist
  ensure_plist_exists "${label}"
  plist="$(plist_for_label "${label}")"
  if [[ "${force}" != "-f" && "${force}" != "--force" ]]; then
    read -r -p "Remove LaunchAgent ${label}? Config and logs are kept. [y/N]: " answer
    if [[ "${answer}" != "y" && "${answer}" != "Y" ]]; then
      echo "Cancelled."
      exit 0
    fi
  fi
  launchctl bootout "gui/${UID_VALUE}" "${plist}" 2>/dev/null || true
  rm -f "${plist}"
  echo "Removed ${label}"
}

cmd_tail() {
  local label="$1"
  local field="$2"
  local path
  ensure_plist_exists "${label}"
  path="$(plist_field "${label}" "${field}")"
  if [[ -z "${path}" ]]; then
    echo "log path not found: ${field}" >&2
    exit 1
  fi
  mkdir -p "$(dirname "${path}")"
  touch "${path}"
  tail -f "${path}"
}

command="${1:-}"
case "${command}" in
  list)
    cmd_list
    ;;
  status)
    [[ $# -ge 2 ]] || { usage; exit 1; }
    cmd_status "$(label_from_arg "$2")"
    ;;
  start|kick)
    [[ $# -ge 2 ]] || { usage; exit 1; }
    cmd_start "$(label_from_arg "$2")"
    ;;
  stop)
    [[ $# -ge 2 ]] || { usage; exit 1; }
    cmd_stop "$(label_from_arg "$2")"
    ;;
  remove|uninstall)
    [[ $# -ge 2 ]] || { usage; exit 1; }
    cmd_remove "$(label_from_arg "$2")" "${3:-}"
    ;;
  logs)
    [[ $# -ge 2 ]] || { usage; exit 1; }
    cmd_tail "$(label_from_arg "$2")" "StandardOutPath"
    ;;
  errors)
    [[ $# -ge 2 ]] || { usage; exit 1; }
    cmd_tail "$(label_from_arg "$2")" "StandardErrorPath"
    ;;
  -h|--help|help|"")
    usage
    ;;
  *)
    echo "unknown command: ${command}" >&2
    usage
    exit 1
    ;;
esac
