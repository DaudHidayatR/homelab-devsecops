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

mkdir -p "$BACKUP_DIR"

# ── Helpers ────────────────────────────────────────────────────────────


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
  INIT_OUTPUT=$(openbao::exec operator init -key-shares=1 -key-threshold=1 -format=json)
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
  openbao::exec operator unseal "$UNSEAL_KEY"
  echo "  OpenBao unsealed."
fi

# ── 4. Login as root ─────────────────────────────────────────────────

ROOT_TOKEN=$(cat "$BACKUP_DIR/root-token.txt")
openbao::exec login "$ROOT_TOKEN" >/dev/null
echo ""
echo "=== Logged in as root ==="

# ── 5. Enable KV v2 secrets engine ───────────────────────────────────

if openbao::exec_quiet secrets list -format=json | python3 -c "import json,sys; d=json.load(sys.stdin); print('secret/' in d)" 2>/dev/null | grep -q True; then
  echo ""
  echo "=== KV v2 already enabled at secret/ ==="
else
  echo ""
  echo "=== Enabling KV v2 secrets engine at secret/ ==="
  openbao::exec secrets enable -path=secret kv-v2
  echo "  KV v2 enabled at secret/."
fi

# ── 6. Enable SSH secrets engine for signed certificates ──────────────

if openbao::exec_quiet secrets list -format=json | python3 -c "import json,sys; d=json.load(sys.stdin); print('ssh-client-signer/' in d)" 2>/dev/null | grep -q True; then
  echo ""
  echo "=== SSH client signer already enabled ==="
else
  echo ""
  echo "=== Enabling SSH secrets engine at ssh-client-signer/ ==="
  openbao::exec secrets enable -path=ssh-client-signer ssh
  echo "  SSH client signer enabled."
fi

# Generate SSH CA keypair if not already present.
SSH_CA_EXISTS=$(openbao::exec_quiet read -field=public_key ssh-client-signer/config/ca 2>/dev/null || true)
if [ -n "$SSH_CA_EXISTS" ]; then
  echo "  SSH CA keypair already exists."
else
  echo "=== Generating SSH CA keypair ==="
  openbao::exec write ssh-client-signer/config/ca generate_signing_key=true
  echo "  SSH CA keypair generated."
  SSH_PUB=$(openbao::exec read -field=public_key ssh-client-signer/config/ca)
  echo "$SSH_PUB" > "$BACKUP_DIR/ssh-client-signer-ca.pub"
  chmod 644 "$BACKUP_DIR/ssh-client-signer-ca.pub"
  echo "  CA public key saved to: $BACKUP_DIR/ssh-client-signer-ca.pub"
fi

# ── 7. Enable Kubernetes auth method ──────────────────────────────────

if openbao::exec_quiet auth list -format=json | python3 -c "import json,sys; d=json.load(sys.stdin); print('kubernetes/' in d)" 2>/dev/null | grep -q True; then
  echo ""
  echo "=== Kubernetes auth already enabled ==="
else
  echo ""
  echo "=== Enabling Kubernetes auth method ==="
  openbao::exec auth enable kubernetes
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
if ! kubectl exec -n "${OPENBAO_NS}" "${OPENBAO_POD}" -- grep -q 'BEGIN CERTIFICATE' /var/run/secrets/kubernetes.io/serviceaccount/ca.crt; then
  echo "ERROR: Kubernetes service account CA is not PEM formatted."
  exit 1
fi

openbao::exec write auth/kubernetes/config \
  "kubernetes_host=${KUBE_HOST}" \
  token_reviewer_jwt=@/var/run/secrets/kubernetes.io/serviceaccount/token \
  kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt

CONFIG_HOST=$(openbao::exec read -field=kubernetes_host auth/kubernetes/config 2>/dev/null || true)
if [ "$CONFIG_HOST" != "$KUBE_HOST" ]; then
  echo "ERROR: OpenBao Kubernetes auth verification failed. Expected '$KUBE_HOST', got '${CONFIG_HOST:-<empty>}'."
  exit 1
fi

echo "  Kubernetes auth configured."

# ── 9. Enable userpass and AppRole auth methods ───────────────────────

if openbao::exec_quiet auth list -format=json | python3 -c "import json,sys; d=json.load(sys.stdin); print('userpass/' in d)" 2>/dev/null | grep -q True; then
  echo ""
  echo "=== Userpass auth already enabled ==="
else
  echo ""
  echo "=== Enabling userpass auth method ==="
  openbao::exec auth enable userpass
  echo "  Userpass auth enabled."
fi

if openbao::exec_quiet auth list -format=json | python3 -c "import json,sys; d=json.load(sys.stdin); print('approle/' in d)" 2>/dev/null | grep -q True; then
  echo ""
  echo "=== AppRole auth already enabled ==="
else
  echo ""
  echo "=== Enabling AppRole auth method ==="
  openbao::exec auth enable approle
  echo "  AppRole auth enabled."
fi

# ── 10. Enable audit logging when path is writable ─────────────────────

if openbao::exec_quiet audit list -format=json | python3 -c "import json,sys; d=json.load(sys.stdin); print('file/' in d)" 2>/dev/null | grep -q True; then
  echo ""
  echo "=== File audit logging already enabled ==="
else
  echo ""
  echo "=== Checking audit log path ==="
  kubectl exec -n "${OPENBAO_NS}" "${OPENBAO_POD}" -- mkdir -p /vault/audit
  if kubectl exec -n "${OPENBAO_NS}" "${OPENBAO_POD}" -- test -w /vault/audit >/dev/null 2>&1; then
    echo "  /vault/audit is writable. Enabling file audit device."
    openbao::exec audit enable file file_path=/vault/audit/audit.log
    echo "  File audit logging enabled at /vault/audit/audit.log."
  else
    echo "  WARNING: /vault/audit is not writable in the OpenBao pod."
    echo "  Skipping file audit enablement. Add a writable audit volume and re-run bootstrap."
  fi
fi

# ── 11. Apply OpenBao policies from repo source of truth ───────────────

echo ""
echo "=== Applying OpenBao policy-as-code files ==="
OPENBAO_TOKEN="${ROOT_TOKEN}" bash "${PROJECT_ROOT}/scripts/openbao/apply-policies.sh"

# ── 12. Seed safe KV hierarchy ────────────────────────────────────────

echo ""
echo "=== Seeding safe KV hierarchy ==="
openbao::exec kv put secret/common/public/cluster-info _seeded=true managed_by=openbao-bootstrap >/dev/null
openbao::exec kv put secret/common/public/ca-public _seeded=true managed_by=openbao-bootstrap >/dev/null
if ! openbao::exec kv get secret/apps/demo/sample-app; then
  openbao::exec kv put secret/apps/demo/sample-app _seeded=true managed_by=openbao-bootstrap >/dev/null
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
  openbao::policy_exists system-admin || common::die "Required policy 'system-admin' is missing after policy reconciliation."
  openbao::exec write auth/userpass/users/openbao-admin "password=${ADMIN_PASSWORD}" policies=system-admin token_ttl=1h token_max_ttl=4h >/dev/null
  echo "  Default admin user configured. Password file: $ADMIN_PASSWORD_FILE"
else
  echo ""
  echo "=== Skipping default openbao-admin user ==="
  echo "  Set OPENBAO_CREATE_DEFAULT_ADMIN=true to create it during bootstrap."
fi

if [ "${OPENBAO_CREATE_DEFAULT_APPROLE:-false}" = "true" ]; then
  echo ""
  echo "=== Ensuring default ci-robot AppRole ==="
  openbao::exec write auth/approle/role/ci-robot token_policies=ci-deployer token_ttl=30m token_max_ttl=2h secret_id_ttl=30m secret_id_num_uses=1 >/dev/null
  echo "  Default ci-robot AppRole configured. Generate wrapped SecretID with scripts/openbao/create-approle.sh."
else
  echo ""
  echo "=== Skipping default ci-robot AppRole ==="
  echo "  Set OPENBAO_CREATE_DEFAULT_APPROLE=true to create it during bootstrap."
fi


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
echo "    1. Reconcile Flux in order: flux reconcile kustomization infrastructure && flux reconcile kustomization apps"
echo "    2. Verify: kubectl get clustersecretstore openbao"
