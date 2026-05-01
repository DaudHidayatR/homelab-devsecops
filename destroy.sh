#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.env"

cleanup_release_namespace() {
  local release_name="$1"
  local namespace_name="$2"
  local label="$3"

  echo "=== Cleaning up ${label} ==="
  helm uninstall "$release_name" --namespace "$namespace_name" 2>/dev/null || true

  echo "    Deleting ${namespace_name} namespace..."
  kubectl delete namespace "$namespace_name" --wait=false 2>/dev/null || true

  local wait_count=0
  while kubectl get namespace "$namespace_name" &>/dev/null && [ $wait_count -lt 30 ]; do
    sleep 1
    wait_count=$((wait_count + 1))
  done

  if kubectl get namespace "$namespace_name" &>/dev/null; then
    echo "    ⚠ Namespace still terminating (kind deletion will remove the rest)"
  fi
}

cleanup_release_namespace openbao openbao "OpenBao"

echo "=== Destroying kind cluster (rootless) ==="
kind delete cluster --name "$CLUSTER_NAME"

echo "=== Teardown Complete! ==="
