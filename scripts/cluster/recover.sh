#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${PROJECT_ROOT}/scripts/lib/common.sh"
COMMON_REQUIRE_CONFIG=true
common::load_config "${PROJECT_ROOT}/config.env"
# shellcheck source=scripts/lib/cluster.sh
source "${PROJECT_ROOT}/scripts/lib/cluster.sh"
# shellcheck source=scripts/lib/tailscale.sh
source "${PROJECT_ROOT}/scripts/lib/tailscale.sh"

BACKUP_DIR="${1:-}"
cluster::validate_name
common::require_commands kind kubectl python3

if cluster::exists; then
  result_file="$(mktemp)"
  trap 'rm -f "${result_file}"' EXIT
  TAILSCALE_BACKUP_RESULT_FILE="${result_file}" bash "${PROJECT_ROOT}/scripts/cluster/destroy.sh"
  [[ -s "${result_file}" ]] || common::die "Cluster destruction produced no Tailscale identity backup; refusing recovery."
  BACKUP_DIR="$(cat "${result_file}")"
else
  [[ -n "${BACKUP_DIR}" ]] || common::die "No cluster exists. Usage: $0 <validated-backup-directory>"
fi
tailscale::validate_identity_file "${BACKUP_DIR}/operator.json"

cluster::ensure_kind "${PROJECT_ROOT}/kind/cluster.yaml"
tailscale::ensure_namespace
"${PROJECT_ROOT}/scripts/tailscale/restore-state.sh" "${BACKUP_DIR}"
TAILSCALE_BACKUP_DIR="${BACKUP_DIR}" bash "${PROJECT_ROOT}/scripts/cluster/setup.sh"
