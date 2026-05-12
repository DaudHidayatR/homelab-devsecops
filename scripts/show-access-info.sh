#!/usr/bin/env bash
set -eo pipefail

# show-access-info.sh — Post-setup access instructions
# Principle: SRP — this script has one reason to change: how users access services.
# setup.sh has one reason to change: infrastructure orchestration.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/config.env"

cat <<EOF
=== Setup Complete! ===
Check pod status with: kubectl get pods -n ${DEMO_NAMESPACE}

--- Tailscale Private Access ---
If TAILSCALE_CLIENT_ID and TAILSCALE_CLIENT_SECRET are set in config.env,
admin UIs are automatically available on your tailnet:
   Headlamp:  https://headlamp-kube-system.<tailnet>.ts.net
   RabbitMQ:  https://rabbitmq-messaging.<tailnet>.ts.net
   OpenBao:   https://openbao-openbao.<tailnet>.ts.net

If Tailscale credentials are not configured, use legacy port-forward access below.

--- Legacy Port-Forward Access ---
To access Headlamp Web UI:
1. Run: kubectl port-forward -n kube-system service/headlamp 8080:80
2. Get your login token: kubectl create token headlamp-admin -n kube-system
3. Open http://localhost:8080 in your browser

To access RabbitMQ Management UI:
1. Run: kubectl port-forward -n messaging svc/rabbitmq 15672:15672
2. Open http://localhost:15672
3. Get the password: kubectl get secret rabbitmq-credentials -n messaging -o jsonpath='{.data.RABBITMQ_DEFAULT_PASS}' | base64 -d

To bootstrap OpenBao (single-node raft):
1. Run: kubectl port-forward -n openbao svc/openbao 8200:8200
2. Initialize once: kubectl exec -it -n openbao openbao-0 -- bao operator init -key-shares=1 -key-threshold=1
3. Unseal with the returned key: kubectl exec -it -n openbao openbao-0 -- bao operator unseal <unseal_key>
4. Open https://localhost:8200 in your browser (accept the self-signed certificate warning)
5. Back up the init output outside the cluster (root token + unseal key)
EOF
