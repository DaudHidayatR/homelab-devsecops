#!/usr/bin/env bash
set -eo pipefail

# Tailscale Kubernetes Operator Installer
# Requires: kubectl, a Tailscale OAuth client or auth key
#
# Before running:
# 1. Create an OAuth client in the Tailscale admin console with "Devices" write scope.
# 2. Create the secret:
#    kubectl create secret generic operator-oauth \
#      --namespace tailscale \
#      --from-literal=client_id=<OAUTH_CLIENT_ID> \
#      --from-literal=client_secret=<OAUTH_CLIENT_SECRET>
#
# Or use an auth key:
#    kubectl create secret generic operator-oauth \
#      --namespace tailscale \
#      --from-literal=oauth_client_id=tskey-client-<ID> \
#      --from-literal=oauth_client_secret=tskey-<SECRET>

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if kubectl get deployment -n tailscale operator &>/dev/null; then
  echo "Tailscale operator already installed. Skipping."
  exit 0
fi

echo "=== Installing Tailscale Kubernetes Operator ==="
kubectl apply -f https://github.com/tailscale/tailscale/releases/latest/download/tailscale-operator.yaml

echo "=== Waiting for operator to be ready ==="
kubectl rollout status deployment/operator -n tailscale --timeout=120s

echo "=== Tailscale operator installed ==="
echo ""
echo "Services annotated with 'tailscale.com/expose: \"true\"' will now be"
echo "accessible from your tailnet at https://<service>-<namespace>.<tailnet>.ts.net"
echo ""
echo "For public internet access, change the annotation to:"
echo "  tailscale.com/funnel: \"true\""
