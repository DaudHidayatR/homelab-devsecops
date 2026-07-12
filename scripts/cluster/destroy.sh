#!/usr/bin/env bash
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=/dev/null
source "${PROJECT_ROOT}/config.env"
# shellcheck source=scripts/lib/cluster.sh
source "${PROJECT_ROOT}/scripts/lib/cluster.sh"

cluster::validate_name

BACKUP_ROOT="${TAILSCALE_BACKUP_DIR:-${PROJECT_ROOT}/.runtime-backups/tailscale}"
BACKUP_DIR="${BACKUP_ROOT}/$(date +%Y%m%d-%H%M%S)"
BACKUP_CREATED="false"

echo "=== Preparing to destroy kind cluster (rootless) ==="
echo "WARNING: This deletes Kubernetes runtime state. For normal app redeploys, use: make redeploy"
echo "WARNING: Deleting the cluster without restoring Tailscale state can create duplicate tailnet devices."

backup_secret() {
  local name="$1" required="$2" temp
  local target="${BACKUP_DIR}/${name}.json"
  temp="$(mktemp "${target}.tmp.XXXXXX")"
  chmod 0600 "$temp"
  if ! kubectl get secret "$name" -n tailscale -o json >"$temp"; then
    rm -f "$temp"
    [ "$required" = false ] || { echo "ERROR: required tailscale/$name Secret is missing" >&2; exit 1; }
    return 0
  fi
  python3 - "$temp" "$required" <<'PY'
import json, sys
p, required = sys.argv[1], sys.argv[2] == 'true'
d = json.load(open(p))
if required and not any(k.startswith(('_machinekey', '_current-profile', 'profile-')) for k in (d.get('data') or {})):
    raise SystemExit('required operator identity keys are missing')
PY
  mv "$temp" "$target"
}

if kubectl get namespace tailscale &>/dev/null; then
  echo "=== Backing up Tailscale Kubernetes state ==="
  install -d -m 0700 "$BACKUP_DIR"
  backup_secret operator true
  backup_secret operator-oauth false
  temp="$(mktemp "${BACKUP_DIR}/all-secrets.json.tmp.XXXXXX")"
  chmod 0600 "$temp"
  kubectl get secrets -n tailscale -o json >"$temp"
  python3 -m json.tool "$temp" >/dev/null
  mv "$temp" "${BACKUP_DIR}/all-secrets.json"
  BACKUP_CREATED="true"
  if [[ -n "${TAILSCALE_BACKUP_RESULT_FILE:-}" ]]; then
    printf '%s\n' "${BACKUP_DIR}" > "${TAILSCALE_BACKUP_RESULT_FILE}"
  fi
else
  echo "=== No tailscale namespace found; skipping Tailscale state backup ==="
fi

echo "=== Destroying kind cluster (rootless) ==="
kind delete cluster --name "$CLUSTER_NAME"

if [ "$BACKUP_CREATED" = "true" ]; then
  echo "=== Tailscale Backup Created ==="
  echo "Backup path: ${BACKUP_DIR}"
  echo "Before reinstalling the operator on a rebuilt cluster, restore it with:"
  echo "  ./scripts/tailscale/restore-state.sh ${BACKUP_DIR}"
fi

echo "=== Teardown Complete! ==="
