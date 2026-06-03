#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=/dev/null
source "${PROJECT_ROOT}/config.env"

BACKUP_ROOT="${TAILSCALE_BACKUP_DIR:-${PROJECT_ROOT}/.runtime-backups/tailscale}"
BACKUP_DIR="${BACKUP_ROOT}/$(date +%Y%m%d-%H%M%S)"
BACKUP_CREATED="false"

echo "=== Preparing to destroy kind cluster (rootless) ==="
echo "WARNING: This deletes Kubernetes runtime state. For normal app redeploys, use: make redeploy"
echo "WARNING: Deleting the cluster without restoring Tailscale state can create duplicate tailnet devices."

if kubectl get namespace tailscale &>/dev/null; then
  echo "=== Backing up Tailscale Kubernetes state ==="
  mkdir -p "$BACKUP_DIR"

  if kubectl get secret operator -n tailscale &>/dev/null; then
    kubectl get secret operator -n tailscale -o json >"${BACKUP_DIR}/operator.json"
    echo "    ✓ Backed up operator identity Secret."
  else
    echo "    ⚠ operator Secret not found; no operator identity to back up."
  fi

  if kubectl get secret operator-oauth -n tailscale &>/dev/null; then
    kubectl get secret operator-oauth -n tailscale -o json >"${BACKUP_DIR}/operator-oauth.json"
    echo "    ✓ Backed up operator OAuth Secret."
  else
    echo "    ⚠ operator-oauth Secret not found; setup.sh can recreate it if config.env has credentials."
  fi

  kubectl get secrets -n tailscale -o json >"${BACKUP_DIR}/all-secrets.json"
  echo "    ✓ Backed up all tailscale namespace Secrets."
  BACKUP_CREATED="true"
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
