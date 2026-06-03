#!/usr/bin/env bash
# Shared shell primitives for infra/kind scripts.

if [[ -n "${KIND_COMMON_SH_LOADED:-}" ]]; then
  return 0
fi
KIND_COMMON_SH_LOADED=1

COMMON_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_REPO_ROOT="$(cd "${COMMON_LIB_DIR}/../.." && pwd)"

: "${CONFIG_FILE:=${COMMON_REPO_ROOT}/config.env}"
: "${NO_COLOR:=false}"
: "${VERBOSE:=false}"
: "${QUIET:=false}"

COMMON_TMP_FILES=()

if [[ -t 1 && "${NO_COLOR}" != "true" ]]; then
  COMMON_COLOR_BLUE=$'\033[34m'
  COMMON_COLOR_GREEN=$'\033[32m'
  COMMON_COLOR_YELLOW=$'\033[33m'
  COMMON_COLOR_RED=$'\033[31m'
  COMMON_COLOR_BOLD=$'\033[1m'
  COMMON_COLOR_RESET=$'\033[0m'
else
  COMMON_COLOR_BLUE=""
  COMMON_COLOR_GREEN=""
  COMMON_COLOR_YELLOW=""
  COMMON_COLOR_RED=""
  COMMON_COLOR_BOLD=""
  COMMON_COLOR_RESET=""
fi

common::repo_root() {
  printf '%s\n' "${COMMON_REPO_ROOT}"
}

common::die() {
  log::error "$*"
  exit 1
}

log::section() {
  [[ "${QUIET}" == "true" ]] && return 0
  printf '\n%s=== %s ===%s\n' "${COMMON_COLOR_BOLD}" "$*" "${COMMON_COLOR_RESET}"
}

log::info() {
  [[ "${QUIET}" == "true" ]] && return 0
  printf '%s[INFO]%s %s\n' "${COMMON_COLOR_BLUE}" "${COMMON_COLOR_RESET}" "$*"
}

log::success() {
  [[ "${QUIET}" == "true" ]] && return 0
  printf '%s[OK]%s %s\n' "${COMMON_COLOR_GREEN}" "${COMMON_COLOR_RESET}" "$*"
}

log::warn() {
  printf '%s[WARN]%s %s\n' "${COMMON_COLOR_YELLOW}" "${COMMON_COLOR_RESET}" "$*" >&2
}

log::error() {
  printf '%s[ERROR]%s %s\n' "${COMMON_COLOR_RED}" "${COMMON_COLOR_RESET}" "$*" >&2
}

log::verbose() {
  [[ "${VERBOSE}" == "true" ]] || return 0
  printf '[VERBOSE] %s\n' "$*"
}

common::load_config() {
  local config_path="${1:-${CONFIG_FILE}}"
  if [[ -f "${config_path}" ]]; then
    # shellcheck source=/dev/null
    source "${config_path}"
    log::verbose "Loaded config: ${config_path}"
  elif [[ "${COMMON_REQUIRE_CONFIG:-false}" == "true" ]]; then
    common::die "Config file not found: ${config_path}. Copy config.env.example to config.env and customize it."
  else
    log::verbose "Config file not found, using environment/defaults: ${config_path}"
  fi
}

common::require_command() {
  local command_name="$1"
  command -v "${command_name}" >/dev/null 2>&1 || common::die "Required command not found: ${command_name}"
}

common::require_commands() {
  local command_name
  for command_name in "$@"; do
    common::require_command "${command_name}"
  done
}

common::require_file() {
  local file_path="$1"
  [[ -f "${file_path}" ]] || common::die "Required file not found: ${file_path}"
}

common::confirm() {
  local prompt="$1"
  if [[ "${YES:-false}" == "true" ]]; then
    return 0
  fi

  local answer
  printf '%s [y/N]: ' "${prompt}"
  read -r answer
  [[ "${answer}" == "y" || "${answer}" == "Y" ]]
}

common::mktemp() {
  local file_path
  file_path="$(mktemp "$@")"
  COMMON_TMP_FILES+=("${file_path}")
  printf '%s\n' "${file_path}"
}

common::mktemp_var() {
  local __var_name="$1"
  shift

  local file_path
  file_path="$(mktemp "$@")"
  COMMON_TMP_FILES+=("${file_path}")
  printf -v "${__var_name}" '%s' "${file_path}"
}

common::abs_path() {
  local path_value="$1"
  if [[ "${path_value}" = /* ]]; then
    printf '%s\n' "${path_value}"
  else
    printf '%s/%s\n' "${COMMON_REPO_ROOT}" "${path_value#./}"
  fi
}

common::cleanup() {
  local file_path
  for file_path in "${COMMON_TMP_FILES[@]:-}"; do
    if [[ -n "${file_path}" ]]; then
      rm -f "${file_path}" 2>/dev/null || true
    fi
  done
}

common::on_error() {
  local line_number="$1"
  local command_text="$2"
  log::error "Command failed at line ${line_number}: ${command_text}"
}

common::install_traps() {
  trap 'common::on_error "$LINENO" "$BASH_COMMAND"' ERR
  trap common::cleanup EXIT
}

json::get_bool() {
  local key="$1"
  local default_value="${2:-False}"
  python3 -c "import json,sys; print(json.load(sys.stdin).get('${key}', ${default_value}))" 2>/dev/null || printf '%s\n' "${default_value}"
}

json::escape() {
  python3 -c 'import json,sys; print(json.dumps(sys.stdin.read())[1:-1])'
}
