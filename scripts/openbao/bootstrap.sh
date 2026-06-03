#!/usr/bin/env bash
# OpenBao Bootstrap Script
# One-time initialization: init, unseal, KV v2, Kubernetes auth, ESO policy & role.
#
# Prerequisites:
#   OpenBao pod must be Running (Flux deploys it via infrastructure/openbao/).
#   Wait for it:  kubectl wait --for=condition=Ready pod/openbao-0 -n openbao --timeout=300s
#
# Usage:
#   bash scripts/openbao/bootstrap.sh

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck source=scripts/lib/common.sh
source "${PROJECT_ROOT}/scripts/lib/common.sh"
common::load_config "${PROJECT_ROOT}/config.env"
# shellcheck source=scripts/lib/openbao.sh
source "${PROJECT_ROOT}/scripts/lib/openbao.sh"

BACKUP_DIR="${OPENBAO_BACKUP_DIR}"
POLICY_DIR="${PROJECT_ROOT}/policies/openbao"
REMOTE_POLICY_DIR="/tmp/openbao-policies"
ESO_NS="${ESO_NAMESPACE:-external-secrets}"
ESO_SA="${ESO_SERVICE_ACCOUNT:-external-secrets}"

# Explicit policy registry.
# Format: policy_name|relative_policy_file
POLICY_FILES=(
  "system-admin|system/system-admin.hcl"
  "audit-metadata-reader|audit/audit-metadata-reader.hcl"
  "secret-kv-admin|secret-engine/secret-kv-admin.hcl"
  "shared-read-public|shared/shared-read-public.hcl"
  "user-default|user/user-default.hcl"
  "user-ssh|user/user-ssh.hcl"
  "app-default|app/app-default.hcl"
  "app-demo|app/app-demo.hcl"
  "app-tailscale-operator|app/app-tailscale-operator.hcl"
  "k8s-eso-reader|kubernetes/k8s-eso-reader.hcl"
  "ci-deployer|ci/ci-deployer.hcl"
)

mkdir -p "$BACKUP_DIR"

# ── Helpers ────────────────────────────────────────────────────────────

_bao_exec() {
  openbao::exec "$@"
}

_bao_exec_quiet() {
  openbao::exec_quiet "$@"
}

_is_initialized() {
  openbao::is_initialized
}

_is_sealed() {
  openbao::is_sealed
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

# ── 6. Enable SSH secrets engine for signed certificates ──────────────

if _bao_exec_quiet "bao secrets list -format=json" | python3 -c "import json,sys; d=json.load(sys.stdin); print('ssh-client-signer/' in d)" 2>/dev/null | grep -q True; then
  echo ""
  echo "=== SSH client signer already enabled ==="
else
  echo ""
  echo "=== Enabling SSH secrets engine at ssh-client-signer/ ==="
  _bao_exec "bao secrets enable -path=ssh-client-signer ssh"
  echo "  SSH client signer enabled."
fi

# Generate SSH CA keypair if not already present.
SSH_CA_EXISTS=$(_bao_exec_quiet "bao read -field=public_key ssh-client-signer/config/ca" 2>/dev/null || true)
if [ -n "$SSH_CA_EXISTS" ]; then
  echo "  SSH CA keypair already exists."
else
  echo "=== Generating SSH CA keypair ==="
  _bao_exec "bao write ssh-client-signer/config/ca generate_signing_key=true"
  echo "  SSH CA keypair generated."
  SSH_PUB=$(_bao_exec "bao read -field=public_key ssh-client-signer/config/ca")
  echo "$SSH_PUB" > "$BACKUP_DIR/ssh-client-signer-ca.pub"
  chmod 644 "$BACKUP_DIR/ssh-client-signer-ca.pub"
  echo "  CA public key saved to: $BACKUP_DIR/ssh-client-signer-ca.pub"
fi

# ── 7. Enable Kubernetes auth method ──────────────────────────────────

if _bao_exec_quiet "bao auth list -format=json" | python3 -c "import json,sys; d=json.load(sys.stdin); print('kubernetes/' in d)" 2>/dev/null | grep -q True; then
  echo ""
  echo "=== Kubernetes auth already enabled ==="
else
  echo ""
  echo "=== Enabling Kubernetes auth method ==="
  _bao_exec "bao auth enable kubernetes"
  echo "  Kubernetes auth enabled."
fi

# ── 8. Configure Kubernetes auth ──────────────────────────────────────

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

# ── 9. Enable userpass and AppRole auth methods ───────────────────────

if _bao_exec_quiet "bao auth list -format=json" | python3 -c "import json,sys; d=json.load(sys.stdin); print('userpass/' in d)" 2>/dev/null | grep -q True; then
  echo ""
  echo "=== Userpass auth already enabled ==="
else
  echo ""
  echo "=== Enabling userpass auth method ==="
  _bao_exec "bao auth enable userpass"
  echo "  Userpass auth enabled."
fi

if _bao_exec_quiet "bao auth list -format=json" | python3 -c "import json,sys; d=json.load(sys.stdin); print('approle/' in d)" 2>/dev/null | grep -q True; then
  echo ""
  echo "=== AppRole auth already enabled ==="
else
  echo ""
  echo "=== Enabling AppRole auth method ==="
  _bao_exec "bao auth enable approle"
  echo "  AppRole auth enabled."
fi

# ── 10. Enable audit logging when path is writable ─────────────────────

if _bao_exec_quiet "bao audit list -format=json" | python3 -c "import json,sys; d=json.load(sys.stdin); print('file/' in d)" 2>/dev/null | grep -q True; then
  echo ""
  echo "=== File audit logging already enabled ==="
else
  echo ""
  echo "=== Checking audit log path ==="
  if _bao_exec "mkdir -p /vault/audit && test -w /vault/audit" >/dev/null 2>&1; then
    echo "  /vault/audit is writable. Enabling file audit device."
    _bao_exec "bao audit enable file file_path=/vault/audit/audit.log"
    echo "  File audit logging enabled at /vault/audit/audit.log."
  else
    echo "  WARNING: /vault/audit is not writable in the OpenBao pod."
    echo "  Skipping file audit enablement. Add a writable audit volume and re-run bootstrap."
  fi
fi

# ── 11. Apply OpenBao policies from repo source of truth ───────────────

echo ""
echo "=== Applying OpenBao policy-as-code files ==="

for policy_entry in "${POLICY_FILES[@]}"; do
  IFS='|' read -r policy relative_path <<< "$policy_entry"
  if [ ! -f "$POLICY_DIR/$relative_path" ]; then
    echo "ERROR: Policy file not found: $POLICY_DIR/$relative_path"
    exit 1
  fi
done

_bao_exec "rm -rf '$REMOTE_POLICY_DIR' && mkdir -p '$REMOTE_POLICY_DIR'"
kubectl cp "$POLICY_DIR/." "${OPENBAO_NS}/${OPENBAO_POD}:${REMOTE_POLICY_DIR}"

for policy_entry in "${POLICY_FILES[@]}"; do
  IFS='|' read -r policy relative_path <<< "$policy_entry"
  _bao_exec "bao policy write '$policy' '${REMOTE_POLICY_DIR}/${relative_path}'"
  echo "  Policy '$policy' applied from $relative_path."
done

# ── 12. Seed safe KV hierarchy ────────────────────────────────────────

echo ""
echo "=== Seeding safe KV hierarchy ==="
_bao_exec "bao kv put secret/common/public/cluster-info _seeded=true managed_by=openbao-bootstrap" >/dev/null
_bao_exec "bao kv put secret/common/public/ca-public _seeded=true managed_by=openbao-bootstrap" >/dev/null
if ! _bao_exec "bao kv get secret/apps/demo/sample-app >/dev/null 2>&1"; then
  _bao_exec "bao kv put secret/apps/demo/sample-app _seeded=true managed_by=openbao-bootstrap" >/dev/null
fi
echo "  Seeded common/public paths and demo placeholder."

# ── 13. Optional default admin user and AppRole ───────────────────────

if [ "${OPENBAO_CREATE_DEFAULT_ADMIN:-false}" = "true" ]; then
  echo ""
  echo "=== Ensuring default openbao-admin user ==="
  ADMIN_PASSWORD_FILE="$BACKUP_DIR/openbao-admin-password.txt"
  if [ -f "$ADMIN_PASSWORD_FILE" ]; then
    ADMIN_PASSWORD="$(tr -d '\n' < "$ADMIN_PASSWORD_FILE")"
  else
    ADMIN_PASSWORD="$(openssl rand -base64 32)"
    echo "$ADMIN_PASSWORD" > "$ADMIN_PASSWORD_FILE"
    chmod 600 "$ADMIN_PASSWORD_FILE"
  fi
  _bao_exec "bao write auth/userpass/users/openbao-admin password='$ADMIN_PASSWORD' policies=admin token_ttl=1h token_max_ttl=4h" >/dev/null
  echo "  Default admin user configured. Password file: $ADMIN_PASSWORD_FILE"
else
  echo ""
  echo "=== Skipping default openbao-admin user ==="
  echo "  Set OPENBAO_CREATE_DEFAULT_ADMIN=true to create it during bootstrap."
fi

if [ "${OPENBAO_CREATE_DEFAULT_APPROLE:-false}" = "true" ]; then
  echo ""
  echo "=== Ensuring default ci-robot AppRole ==="
  _bao_exec "bao write auth/approle/role/ci-robot token_policies=ci-deployer token_ttl=30m token_max_ttl=2h secret_id_ttl=30m secret_id_num_uses=1" >/dev/null
  echo "  Default ci-robot AppRole configured. Generate wrapped SecretID with scripts/openbao/create-approle.sh."
else
  echo ""
  echo "=== Skipping default ci-robot AppRole ==="
  echo "  Set OPENBAO_CREATE_DEFAULT_APPROLE=true to create it during bootstrap."
fi

# ── 14. Create ESO Kubernetes auth role ───────────────────────────────

echo ""
echo "=== Creating ESO Kubernetes auth role ==="

_bao_exec "bao write auth/kubernetes/role/k8s-eso-reader \
  bound_service_account_names='$ESO_SA' \
  bound_service_account_namespaces='$ESO_NS' \
  policies=k8s-eso-reader \
  ttl=1h"

echo "  Role 'k8s-eso-reader' created (SA: $ESO_SA, NS: $ESO_NS)."

# ── 11. Summary ──────────────────────────────────────────────────────

echo ""
echo "═══════════════════════════════════════════════"
echo "  OpenBao bootstrap complete."
echo ""
echo "  Root token:  $BACKUP_DIR/root-token.txt"
echo "  Unseal key:  $BACKUP_DIR/unseal-key.txt"
echo ""
echo "  Secrets engine:  secret/ (KV v2)"
echo "  Auth methods:    kubernetes/, userpass/, approle/"
echo "  Policies:        applied from explicit policies/openbao functional registry"
echo "  Role:            kubernetes/k8s-eso-reader"
echo "    → bound to SA: $ESO_SA in namespace $ESO_NS"
echo ""
echo "  Optional next steps:"
echo "    - Create admin user: OPENBAO_CREATE_DEFAULT_ADMIN=true bash scripts/openbao/bootstrap.sh"
echo "    - Create AppRole:    bash scripts/openbao/create-approle.sh ci-robot ci-deployer"
echo "    - After verifying a non-root admin login, secure or revoke the root token manually."
echo ""
echo "  Next steps:"
echo "    1. Run: bash scripts/openbao/store-rabbitmq.sh"
echo "    2. Reconcile ExternalSecret resources: kubectl apply -k infrastructure/external-secrets/stores"
echo "    3. Verify: kubectl get externalsecret -A"
