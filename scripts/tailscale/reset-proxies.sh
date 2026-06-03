#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BACKUP_ROOT="${TAILSCALE_BACKUP_DIR:-${REPO_ROOT}/.runtime-backups/tailscale}"
BACKUP_DIR="${BACKUP_ROOT}/reset-proxies-$(date +%Y%m%d-%H%M%S)"

if ! kubectl get namespace tailscale &>/dev/null; then
  echo "tailscale namespace does not exist. Nothing to reset."
  exit 0
fi

mkdir -p "$BACKUP_DIR"
kubectl get secrets -n tailscale -o yaml > "${BACKUP_DIR}/all-secrets.yaml"
echo "Backed up tailscale Secrets to: ${BACKUP_DIR}/all-secrets.yaml"

mapfile -t PROXY_SECRETS < <(kubectl get secrets -n tailscale -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | grep '^ts-' || true)

SECRETS_TO_DELETE=()
if kubectl get secret operator -n tailscale &>/dev/null; then
  SECRETS_TO_DELETE+=(operator)
fi
for secret in "${PROXY_SECRETS[@]}"; do
  SECRETS_TO_DELETE+=("$secret")
done

if [ "${#SECRETS_TO_DELETE[@]}" -gt 0 ]; then
  echo "Deleting stale Tailscale identity Secrets: ${SECRETS_TO_DELETE[*]}"
  kubectl delete secret -n tailscale "${SECRETS_TO_DELETE[@]}"
else
  echo "No Tailscale identity Secrets found to delete."
fi

if kubectl get deployment operator -n tailscale &>/dev/null; then
  echo "Restarting Tailscale operator..."
  kubectl rollout restart deployment/operator -n tailscale
  kubectl rollout status deployment/operator -n tailscale --timeout=180s
fi

mapfile -t PROXY_PODS < <(kubectl get pods -n tailscale \
  -l tailscale.com/managed=true,tailscale.com/parent-resource-type=svc \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)

if [ "${#PROXY_PODS[@]}" -gt 0 ]; then
  echo "Restarting Tailscale proxy pods: ${PROXY_PODS[*]}"
  kubectl delete pod -n tailscale "${PROXY_PODS[@]}"
  kubectl wait --for=condition=Ready pod -n tailscale \
    -l tailscale.com/managed=true,tailscale.com/parent-resource-type=svc \
    --timeout=180s
else
  echo "No Tailscale proxy pods found."
fi

cat <<EOF
Reset complete.

Next steps when Tailnet Lock is enabled:
  ./scripts/tailscale/sign-proxies.sh
  ./scripts/tailscale/configure-serve.sh
  ./scripts/tailscale/check-access.sh
EOF
