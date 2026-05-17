#!/usr/bin/env bash
# OpenBao Bootstrap Script
# One-time initialization: init, unseal, KV v2, Kubernetes auth, ESO policy & role.
#
# Prerequisites:
#   OpenBao pod must be Running (Flux deploys it via infrastructure/openbao/).
#   Wait for it:  kubectl wait --for=condition=Ready pod/openbao-0 -n openbao --timeout=300s
#
# Usage:
#   bash scripts/openbao-bootstrap.sh

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="${SCRIPT_DIR}/../.runtime-backups/openbao"
POLICY_DIR="${SCRIPT_DIR}/../policies/openbao"
REMOTE_POLICY_DIR="/tmp/openbao-policies"
OPENBAO_POD="openbao-0"
OPENBAO_NS="openbao"
ESO_NS="external-secrets"
ESO_SA="external-secrets"

mkdir -p "$BACKUP_DIR"

# ── Helpers ────────────────────────────────────────────────────────────

_bao_exec() {
  kubectl exec -n "$OPENBAO_NS" "$OPENBAO_POD" -- sh -c "
    export BAO_ADDR='http://127.0.0.1:8200'
    $*"
}

_bao_exec_quiet() {
  _bao_exec "$@" 2>/dev/null || true
}

_is_initialized() {
  local status
  status=$(_bao_exec_quiet "bao status -format=json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('initialized',False))" 2>/dev/null || echo "False")
  [ "$status" = "True" ]
}

_is_sealed() {
  local sealed
  sealed=$(_bao_exec_quiet "bao status -format=json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('sealed',True))" 2>/dev/null || echo "True")
  [ "$sealed" = "True" ]
}

# ── 1. Wait for pod readiness ──────────────────────────────────────────

echo "=== OpenBao Bootstrap ==="
echo ""

if ! kubectl get pod "$OPENBAO_POD" -n "$OPENBAO_NS" &>/dev/null; then
  echo "ERROR: OpenBao pod '$OPENBAO_POD' not found in namespace '$OPENBAO_NS'."
  echo "Deploy the cluster first: make up"
  exit 1
fi

echo "Waiting for OpenBao pod to be ready..."
kubectl wait --for=condition=Ready "pod/${OPENBAO_POD}" -n "$OPENBAO_NS" --timeout=300s
echo "  OpenBao pod is ready."

# ── 2. Initialize ────────────────────────────────────────────────────

if _is_initialized; then
  echo ""
  echo "=== OpenBao already initialized ==="
else
  echo ""
  echo "=== Initializing OpenBao ==="
  INIT_OUTPUT=$(_bao_exec "bao operator init -key-shares=1 -key-threshold=1 -format=json")
  UNSEAL_KEY=$(echo "$INIT_OUTPUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['unseal_keys_b64'][0])")
  ROOT_TOKEN=$(echo "$INIT_OUTPUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['root_token'])")

  # Save to backup directory
  echo "$UNSEAL_KEY" > "$BACKUP_DIR/unseal-key.txt"
  echo "$ROOT_TOKEN" > "$BACKUP_DIR/root-token.txt"
  chmod 600 "$BACKUP_DIR/unseal-key.txt" "$BACKUP_DIR/root-token.txt"
  echo "  Initialization complete."
  echo "  Unseal key saved to:   $BACKUP_DIR/unseal-key.txt"
  echo "  Root token saved to:   $BACKUP_DIR/root-token.txt"
  echo "  BACK UP THESE FILES outside the VPS immediately."
fi

# ── 3. Unseal ────────────────────────────────────────────────────────

if ! _is_sealed; then
  echo ""
  echo "=== OpenBao already unsealed ==="
else
  echo ""
  echo "=== Unsealing OpenBao ==="

  if [ ! -f "$BACKUP_DIR/unseal-key.txt" ]; then
    echo "ERROR: Unseal key not found at $BACKUP_DIR/unseal-key.txt"
    echo "Cannot unseal OpenBao. Provide the unseal key and re-run."
    exit 1
  fi

  UNSEAL_KEY=$(cat "$BACKUP_DIR/unseal-key.txt")
  _bao_exec "bao operator unseal '$UNSEAL_KEY'"
  echo "  OpenBao unsealed."
fi

# ── 4. Login as root ─────────────────────────────────────────────────

ROOT_TOKEN=$(cat "$BACKUP_DIR/root-token.txt")
_bao_exec "bao login '$ROOT_TOKEN'" >/dev/null
echo ""
echo "=== Logged in as root ==="

# ── 5. Enable KV v2 secrets engine ───────────────────────────────────

if _bao_exec_quiet "bao secrets list -format=json" | python3 -c "import json,sys; d=json.load(sys.stdin); print('secret/' in d)" 2>/dev/null | grep -q True; then
  echo ""
  echo "=== KV v2 already enabled at secret/ ==="
else
  echo ""
  echo "=== Enabling KV v2 secrets engine at secret/ ==="
  _bao_exec "bao secrets enable -path=secret kv-v2"
  echo "  KV v2 enabled at secret/."
fi

# ── 6. Enable Kubernetes auth method ──────────────────────────────────

if _bao_exec_quiet "bao auth list -format=json" | python3 -c "import json,sys; d=json.load(sys.stdin); print('kubernetes/' in d)" 2>/dev/null | grep -q True; then
  echo ""
  echo "=== Kubernetes auth already enabled ==="
else
  echo ""
  echo "=== Enabling Kubernetes auth method ==="
  _bao_exec "bao auth enable kubernetes"
  echo "  Kubernetes auth enabled."
fi

# ── 7. Configure Kubernetes auth ──────────────────────────────────────

echo ""
echo "=== Configuring Kubernetes auth ==="

# Use the stable in-cluster Kubernetes API DNS name. Do not rely on
# KUBERNETES_SERVICE_HOST from this host shell; those variables only exist
# inside Kubernetes pods and are commonly empty when this script is run locally.
KUBE_HOST="https://kubernetes.default.svc:443"

if ! [[ "$KUBE_HOST" =~ ^https://[^:]+:[0-9]+$ ]]; then
  echo "ERROR: Invalid Kubernetes API host for OpenBao auth: $KUBE_HOST"
  exit 1
fi

# Use the OpenBao pod's service account token and Kubernetes API CA directly
# from their mounted files. The CA must be passed as PEM content, not base64.
if ! _bao_exec "grep -q 'BEGIN CERTIFICATE' /var/run/secrets/kubernetes.io/serviceaccount/ca.crt"; then
  echo "ERROR: Kubernetes service account CA is not PEM formatted."
  exit 1
fi

_bao_exec "bao write auth/kubernetes/config \
  kubernetes_host='$KUBE_HOST' \
  token_reviewer_jwt=@/var/run/secrets/kubernetes.io/serviceaccount/token \
  kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"

CONFIG_HOST=$(_bao_exec "bao read -field=kubernetes_host auth/kubernetes/config" 2>/dev/null || true)
if [ "$CONFIG_HOST" != "$KUBE_HOST" ]; then
  echo "ERROR: OpenBao Kubernetes auth verification failed. Expected '$KUBE_HOST', got '${CONFIG_HOST:-<empty>}'."
  exit 1
fi

echo "  Kubernetes auth configured."

# ── 8. Apply OpenBao policies from repo source of truth ───────────────

echo ""
echo "=== Applying OpenBao policy-as-code files ==="

for policy_file in admin.hcl eso-reader.hcl ci-deployer.hcl app-demo.hcl tailscale-operator.hcl; do
  if [ ! -f "$POLICY_DIR/$policy_file" ]; then
    echo "ERROR: Required policy file not found: $POLICY_DIR/$policy_file"
    exit 1
  fi
done

_bao_exec "rm -rf '$REMOTE_POLICY_DIR' && mkdir -p '$REMOTE_POLICY_DIR'"
kubectl cp "$POLICY_DIR/." "${OPENBAO_NS}/${OPENBAO_POD}:${REMOTE_POLICY_DIR}"

for policy in admin eso-reader ci-deployer app-demo tailscale-operator; do
  _bao_exec "bao policy write '$policy' '${REMOTE_POLICY_DIR}/${policy}.hcl'"
  echo "  Policy '$policy' applied."
done

# ── 9. Create ESO Kubernetes auth role ───────────────────────────────

echo ""
echo "=== Creating ESO Kubernetes auth role ==="

_bao_exec "bao write auth/kubernetes/role/eso-reader \
  bound_service_account_names='$ESO_SA' \
  bound_service_account_namespaces='$ESO_NS' \
  policies=eso-reader \
  ttl=1h"

echo "  Role 'eso-reader' created (SA: $ESO_SA, NS: $ESO_NS)."

# ── 10. Summary ──────────────────────────────────────────────────────

echo ""
echo "═══════════════════════════════════════════════"
echo "  OpenBao bootstrap complete."
echo ""
echo "  Root token:  $BACKUP_DIR/root-token.txt"
echo "  Unseal key:  $BACKUP_DIR/unseal-key.txt"
echo ""
echo "  Secrets engine:  secret/ (KV v2)"
echo "  Auth method:     kubernetes/"
echo "  Policies:        admin, eso-reader, ci-deployer, app-demo, tailscale-operator"
echo "  Role:            kubernetes/eso-reader"
echo "    → bound to SA: $ESO_SA in namespace $ESO_NS"
echo ""
echo "  Next steps:"
echo "    1. Run: bash scripts/openbao-store-rabbitmq.sh"
echo "    2. Reconcile ExternalSecret resources: kubectl apply -k infrastructure/external-secrets/stores"
echo "    3. Verify: kubectl get externalsecret -A"
