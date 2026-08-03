#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
umask 077
PROJECT_ROOT="$ROOT_DIR"
# shellcheck source=scripts/lib/common.sh
source "${PROJECT_ROOT}/scripts/lib/common.sh"
common::load_config "${PROJECT_ROOT}/config.env"
# shellcheck source=scripts/lib/openbao.sh
source "${PROJECT_ROOT}/scripts/lib/openbao.sh"

command_openbao_bootstrap() {
  (
# OpenBao Bootstrap Script
# One-time initialization: init, unseal, KV v2, and Kubernetes/userpass/AppRole auth.
#
# Prerequisites:
#   OpenBao pod must be Running (Flux deploys it from kubernetes/clusters/homelab/platform/openbao/).
#   Wait for it:  kubectl wait --for=condition=Ready pod/openbao-0 -n openbao --timeout=300s
#
# Usage:
#   scripts/homelab openbao bootstrap

set -Eeuo pipefail

BACKUP_DIR="${OPENBAO_BACKUP_DIR}"

install -d -m 0700 "$BACKUP_DIR"

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

if openbao::is_initialized; then
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

if ! openbao::is_sealed; then
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
OPENBAO_TOKEN="${ROOT_TOKEN}" command_openbao_policies

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
  echo "  Default ci-robot AppRole configured. Generate wrapped SecretID with scripts/homelab openbao create-approle."
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
echo "  Policies:        applied from the cluster-scoped OpenBao policy registry"
echo ""
echo "  Optional next steps:"
echo "    - Create admin user: OPENBAO_CREATE_DEFAULT_ADMIN=true scripts/homelab openbao bootstrap"
echo "    - Create AppRole:    scripts/homelab openbao create-approle ci-robot ci-deployer"
echo "    - After verifying a non-root admin login, secure or revoke the root token manually."
echo ""
echo "  Next step: verify OpenBao access with: make openbao-status"
  )
}

command_openbao_policies() {
  (
# Apply OpenBao policy-as-code files from the cluster-scoped configuration registry.
#
# This script makes the repo the source of truth for OpenBao policies.
# It is safe to re-run: bao policy write overwrites policies atomically,
# identity entities are updated in place, and auth roles are overwritten.
#
# Usage:
#   scripts/homelab openbao policies
#
# Optional:
#   OPENBAO_TOKEN=<token> scripts/homelab openbao policies
#   GITHUB_REPOSITORY=owner/repo scripts/homelab openbao policies --enable-jwt

set -Eeuo pipefail

POLICY_DIR="${PROJECT_ROOT}/kubernetes/clusters/homelab/platform/openbao/configuration/policies"
ENABLE_JWT="false"
SSH_ROLE_NAME="admin"
SSH_ALLOWED_USERS="*"
SSH_DEFAULT_USER="ubuntu"

# Explicit policy registry.
# Format: policy_name|relative_policy_file
# Keep this explicit so nested policy directories do not automatically grant access.
POLICY_FILES=(
  "system-admin|platform/system-admin.hcl"
  "audit-metadata-reader|platform/audit-metadata-reader.hcl"
  "secret-kv-admin|platform/secret-kv-admin.hcl"
  "shared-read-public|platform/shared-read-public.hcl"
  "user-default|platform/user-default.hcl"
  "user-ssh|platform/user-ssh.hcl"
  "app-default|apps/app-default.hcl"
  "app-demo|apps/app-demo.hcl"
  "app-tailscale-operator|apps/app-tailscale-operator.hcl"
  "ci-deployer|apps/ci-deployer.hcl"
)

# Kubernetes auth/entity mapping table.
# Format: policy_name|namespace|service_account|create_kubernetes_role|create_identity_alias
#
# Keep this explicit. A policy file alone does not imply a Kubernetes principal.
# CI/CD uses optional GitHub OIDC JWT auth for ci-deployer; the Kubernetes role is
# retained here for clusters that also run an in-cluster ci-deployer service account.
POLICY_MAPPINGS=(
  "app-demo|demo|default|true|true"
  "app-tailscale-operator|tailscale|operator|true|true"
  "ci-deployer|flux-system|ci-deployer|true|true"
  "system-admin|kube-system|headlamp-admin|true|true"
)

if [ "${1:-}" = "--enable-jwt" ]; then
  ENABLE_JWT="true"
fi


policy_exists_in_repo() {
  local requested_policy="$1"
  local policy
  local relative_path

  for policy_entry in "${POLICY_FILES[@]}"; do
    IFS='|' read -r policy relative_path <<< "$policy_entry"
    if [ "$policy" = "$requested_policy" ] && [ -f "$POLICY_DIR/$relative_path" ]; then
      return 0
    fi
  done

  return 1
}

validate_policy_registry() {
  local policy
  local relative_path

  for policy_entry in "${POLICY_FILES[@]}"; do
    IFS='|' read -r policy relative_path <<< "$policy_entry"
    common::require_file "$POLICY_DIR/$relative_path"
  done
}

ensure_entity_and_alias() {
  local policy="$1"
  local namespace="$2"
  local service_account="$3"
  local create_alias="$4"
  local entity_id
  local accessor
  local alias_name

  if openbao::exec read identity/entity/name/"$policy"; then
    entity_id=$(openbao::exec read -field=id identity/entity/name/"$policy")
    openbao::exec write identity/entity/id/"${entity_id}" \
      policies="${policy}" \
      metadata=managed_by=openbao-apply-policies \
      metadata=policy="${policy}" \
      metadata=service_account_namespace="${namespace}" \
      metadata=service_account_name="${service_account}" >/dev/null
  else
    entity_id=$(openbao::exec write -field=id identity/entity \
      name="${policy}" \
      policies="${policy}" \
      metadata=managed_by=openbao-apply-policies \
      metadata=policy="${policy}" \
      metadata=service_account_namespace="${namespace}" \
      metadata=service_account_name="${service_account}")
  fi

  echo "  Ensured entity: identity/entity/name/$policy"

  if [ "$create_alias" = "true" ]; then
    accessor=$(openbao::exec read -field=accessor sys/auth/kubernetes)
    alias_name="system:serviceaccount:${namespace}:${service_account}"
    openbao::exec write identity/entity-alias \
      name="${alias_name}" \
      canonical_id="${entity_id}" \
      mount_accessor="${accessor}" >/dev/null
    echo "  Ensured alias: $alias_name"
  fi
}

ensure_kubernetes_role() {
  local policy="$1"
  local namespace="$2"
  local service_account="$3"

  openbao::exec write auth/kubernetes/role/"${policy}" \
    bound_service_account_names="${service_account}" \
    bound_service_account_namespaces="${namespace}" \
    policies="${policy}" \
    ttl=1h >/dev/null

  echo "  Ensured Kubernetes role: auth/kubernetes/role/$policy -> ${namespace}/${service_account}"
}

echo "=== OpenBao Policy-as-Code Apply ==="
echo ""

if ! kubectl get pod "$OPENBAO_POD" -n "$OPENBAO_NS" &>/dev/null; then
  echo "ERROR: OpenBao pod '$OPENBAO_POD' not found in namespace '$OPENBAO_NS'."
  echo "Deploy the cluster first: make up"
  exit 1
fi

kubectl wait --for=condition=Ready "pod/${OPENBAO_POD}" -n "$OPENBAO_NS" --timeout=300s

validate_policy_registry

ROOT_TOKEN="$(openbao::load_root_token)"

# Verify authentication without printing or storing the token in OpenBao CLI config.
openbao::exec token lookup
echo "Authenticated to OpenBao."
echo ""


echo "=== Applying policies from registry ==="
for policy_entry in "${POLICY_FILES[@]}"; do
  IFS='|' read -r policy relative_path <<< "$policy_entry"
  openbao::exec_stdin policy write "${policy}" - < "${POLICY_DIR}/${relative_path}"
  echo "  Applied policy: $policy ($relative_path)"
done
echo ""

echo "=== Ensuring mapped Kubernetes roles, entities, and aliases ==="
for mapping in "${POLICY_MAPPINGS[@]}"; do
  IFS='|' read -r policy namespace service_account create_role create_alias <<< "$mapping"

  if ! policy_exists_in_repo "$policy"; then
    echo "  Skipping mapping for '$policy': policy is not present in POLICY_FILES or file is missing."
    continue
  fi

  if [ "$create_role" = "true" ]; then
    ensure_kubernetes_role "$policy" "$namespace" "$service_account"
  fi

  ensure_entity_and_alias "$policy" "$namespace" "$service_account" "$create_alias"
done
echo ""

# ── Ensure SSH client-signer role for admin ─────────────────────────

echo "=== Ensuring SSH client-signer admin role ==="

if openbao::exec_quiet secrets list -format=json | python3 -c "import json,sys; d=json.load(sys.stdin); print('ssh-client-signer/' in d)" 2>/dev/null | grep -q True; then
  openbao::exec write ssh-client-signer/roles/"${SSH_ROLE_NAME}" \
    algorithm_signer=rsa-sha2-256 \
    allow_user_certificates=true \
    allowed_users="${SSH_ALLOWED_USERS}" \
    default_user="${SSH_DEFAULT_USER}" \
    key_type=ca \
    ttl=30m >/dev/null
  echo "  Ensured SSH role: ssh-client-signer/roles/$SSH_ROLE_NAME"
  echo "    allowed_users: $SSH_ALLOWED_USERS"
  echo "    default_user:  $SSH_DEFAULT_USER"
else
  echo "  SSH secrets engine not enabled at ssh-client-signer/."
  echo "  Enable it first: bao secrets enable -path=ssh-client-signer ssh"
fi
echo ""

if [ "$ENABLE_JWT" = "true" ]; then
  if [ -z "${GITHUB_REPOSITORY:-}" ]; then
    echo "ERROR: --enable-jwt requires GITHUB_REPOSITORY=owner/repo"
    exit 1
  fi

  echo "=== Ensuring GitHub OIDC JWT auth ==="
  if openbao::exec_quiet auth list -format=json | python3 -c "import json,sys; d=json.load(sys.stdin); print('jwt/' in d)" 2>/dev/null | grep -q True; then
    echo "  JWT auth already enabled."
  else
    openbao::exec auth enable jwt
    echo "  Enabled JWT auth."
  fi

  openbao::exec write auth/jwt/config \
    oidc_discovery_url=https://token.actions.githubusercontent.com \
    bound_issuer=https://token.actions.githubusercontent.com >/dev/null

  BOUND_CLAIMS="{\"sub\":\"repo:${GITHUB_REPOSITORY}:ref:refs/tags/v*\"}"
  openbao::exec write auth/jwt/role/ci-deployer \
    role_type=jwt \
    user_claim=sub \
    bound_claims_type=glob \
    bound_claims="${BOUND_CLAIMS}" \
    policies=ci-deployer \
    ttl=15m >/dev/null
  echo "  Ensured role: auth/jwt/role/ci-deployer for repo ${GITHUB_REPOSITORY} tag releases."
  echo ""
else
  echo "=== Skipping GitHub OIDC JWT auth ==="
  echo "  Run with: GITHUB_REPOSITORY=owner/repo scripts/homelab openbao policies --enable-jwt"
  echo ""
fi

echo "=== Verification ==="
echo "Policies:"
openbao::exec policy list
echo ""
echo "Kubernetes roles:"
openbao::exec list auth/kubernetes/role
echo ""
echo "Entities:"
openbao::exec list identity/entity/name
echo ""
echo "OpenBao policy-as-code apply complete."
  )
}

command_openbao_status() {
  (
# OpenBao diagnostic status script.
# Read-only and safe to run against uninitialized, sealed, or unsealed clusters.

set -Eeuo pipefail

BACKUP_DIR="${OPENBAO_BACKUP_DIR}"


print_section() {
  echo ""
  echo "=== $1 ==="
}

if ! kubectl get pod "$OPENBAO_POD" -n "$OPENBAO_NS" >/dev/null 2>&1; then
  echo "OpenBao pod '$OPENBAO_POD' not found in namespace '$OPENBAO_NS'."
  exit 0
fi

print_section "Pod"
kubectl get pod "$OPENBAO_POD" -n "$OPENBAO_NS"

print_section "Seal Status"
STATUS_JSON="$(openbao::exec_quiet status -format=json)"
if [ -z "$STATUS_JSON" ]; then
  echo "Unable to read OpenBao status. Pod may not be ready."
  exit 0
fi
printf '%s\n' "$STATUS_JSON" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    print("Unable to parse status JSON")
    sys.exit(0)
for key in ("initialized", "sealed", "version", "storage_type", "cluster_name", "cluster_id"):
    if key in data:
        print(f"{key}: {data[key]}")
' || true

INITIALIZED=$(printf '%s\n' "$STATUS_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin).get('initialized', False))" 2>/dev/null || echo False)
SEALED=$(printf '%s\n' "$STATUS_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin).get('sealed', True))" 2>/dev/null || echo True)

if [ "$INITIALIZED" != "True" ] || [ "$SEALED" = "True" ]; then
  echo "OpenBao is not initialized or is sealed; skipping authenticated diagnostics."
  exit 0
fi

if [ -z "${OPENBAO_TOKEN:-}" ] && [ -f "$BACKUP_DIR/root-token.txt" ]; then
  OPENBAO_TOKEN="$(tr -d '\n' < "$BACKUP_DIR/root-token.txt")"
fi

if [ -z "${OPENBAO_TOKEN:-}" ]; then
  echo "OPENBAO_TOKEN not set and no root token backup found at $BACKUP_DIR/root-token.txt."
  echo "Skipping authenticated diagnostics."
  exit 0
fi

print_section "Auth Methods"
openbao::exec auth list || true

print_section "Secrets Engines"
openbao::exec secrets list || true

print_section "Audit Devices"
openbao::exec audit list || true

print_section "Policies"
openbao::exec policy list || true

print_section "Kubernetes Roles"
openbao::exec list auth/kubernetes/role || true

print_section "Entities"
openbao::exec list identity/entity/name || true

print_section "Current Token"
openbao::exec token lookup || true
  )
}

command_openbao_create_user() {
  (
# Create or update OpenBao userpass users and optional per-user SSH signing roles.

set -Eeuo pipefail

BACKUP_DIR="${OPENBAO_BACKUP_DIR}"
DEFAULT_POLICY="user-default"
SSH_ENABLED="false"

usage() {
  cat <<USAGE
Usage:
  OPENBAO_USER=<username> OPENBAO_PASSWORD=<password> [OPENBAO_POLICY=user-default] [OPENBAO_SSH=true] scripts/homelab openbao create-user
USAGE
}

if [ "$#" -ne 0 ] || [ -z "${OPENBAO_USER:-}" ] || [ -z "${OPENBAO_PASSWORD:-}" ]; then
  usage
  exit 1
fi

USERNAME="${OPENBAO_USER}"
PASSWORD="${OPENBAO_PASSWORD}"
POLICIES="${OPENBAO_POLICY:-$DEFAULT_POLICY}"
case "${OPENBAO_SSH:-false}" in
  true) SSH_ENABLED="true" ;;
  false|"") ;;
  *) echo "ERROR: OPENBAO_SSH must be true or false" >&2; exit 1 ;;
esac

if ! [[ "$USERNAME" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "ERROR: Username must match ^[A-Za-z0-9._-]+$" >&2
  exit 1
fi

if ! [[ "$POLICIES" =~ ^[A-Za-z0-9._-]+(,[A-Za-z0-9._-]+)*$ ]]; then
  echo "ERROR: Policies must be a comma-separated list matching ^[A-Za-z0-9._-]+(,[A-Za-z0-9._-]+)*$" >&2
  exit 1
fi

IFS=',' read -r -a POLICY_LIST <<< "$POLICIES"

mkdir -p "$BACKUP_DIR/users"

ROOT_TOKEN="$(openbao::load_root_token)"


if ! kubectl get pod "$OPENBAO_POD" -n "$OPENBAO_NS" >/dev/null 2>&1; then
  echo "ERROR: OpenBao pod '$OPENBAO_POD' not found in namespace '$OPENBAO_NS'." >&2
  exit 1
fi

kubectl wait --for=condition=Ready "pod/${OPENBAO_POD}" -n "$OPENBAO_NS" --timeout=300s >/dev/null
openbao::exec token lookup

if ! openbao::exec_quiet auth list -format=json | python3 -c "import json,sys; print('userpass/' in json.load(sys.stdin))" 2>/dev/null | grep -q True; then
  echo "ERROR: userpass auth is not enabled. Run bootstrap first." >&2
  exit 1
fi

for policy in "${POLICY_LIST[@]}"; do
  if ! openbao::exec_quiet policy read "$policy"; then
    echo "ERROR: Policy '$policy' does not exist." >&2
    exit 1
  fi
done

echo "=== Ensuring userpass user '$USERNAME' ==="
openbao::exec write auth/userpass/users/"${USERNAME}" "password=${PASSWORD}" "policies=${POLICIES}" token_ttl=1h token_max_ttl=4h >/dev/null
echo "  Userpass user configured with policies: $POLICIES"

ACCESSOR="$(openbao::exec read -field=accessor sys/auth/userpass)"
ENTITY_NAME="user-${USERNAME}"

if openbao::exec read identity/entity/name/"$ENTITY_NAME"; then
  ENTITY_ID="$(openbao::exec read -field=id identity/entity/name/"$ENTITY_NAME")"
  openbao::exec write identity/entity/id/"${ENTITY_ID}" \
    "policies=${POLICIES}" \
    metadata=managed_by=openbao-create-user \
    "metadata=username=${USERNAME}" \
    "metadata=policy=${POLICIES}" \
    "metadata=policies=${POLICIES}" \
    "metadata=ssh_enabled=${SSH_ENABLED}" >/dev/null
else
  ENTITY_ID="$(openbao::exec write -field=id identity/entity \
    "name=${ENTITY_NAME}" \
    "policies=${POLICIES}" \
    metadata=managed_by=openbao-create-user \
    "metadata=username=${USERNAME}" \
    "metadata=policy=${POLICIES}" \
    "metadata=policies=${POLICIES}" \
    "metadata=ssh_enabled=${SSH_ENABLED}")"
fi

echo "  Entity: $ENTITY_NAME ($ENTITY_ID)"

openbao::exec write identity/entity-alias \
  "name=${USERNAME}" \
  "canonical_id=${ENTITY_ID}" \
  "mount_accessor=${ACCESSOR}" >/dev/null
echo "  Alias: $USERNAME -> $ENTITY_ID"

openbao::exec kv put secret/users/"${ENTITY_ID}"/profile \
  "username=${USERNAME}" \
  "policy=${POLICIES}" \
  "policies=${POLICIES}" \
  "ssh_enabled=${SSH_ENABLED}" \
  managed_by=openbao-create-user >/dev/null
echo "  Stored non-sensitive metadata at secret/users/${ENTITY_ID}/profile"

if [ "$SSH_ENABLED" = "true" ]; then
  if openbao::exec_quiet secrets list -format=json | python3 -c "import json,sys; print('ssh-client-signer/' in json.load(sys.stdin))" 2>/dev/null | grep -q True; then
    openbao::exec write ssh-client-signer/roles/"${ENTITY_ID}" \
      algorithm_signer=rsa-sha2-256 \
      allow_user_certificates=true \
      "allowed_users=${USERNAME}" \
      "default_user=${USERNAME}" \
      key_type=ca \
      ttl=1h >/dev/null
    echo "  SSH role: ssh-client-signer/roles/$ENTITY_ID (allowed_users=$USERNAME)"
  else
    echo "  WARNING: ssh-client-signer/ secrets engine is not enabled; SSH role not created."
  fi
fi

USER_BACKUP="$BACKUP_DIR/users/${USERNAME}.json"
python3 - <<PY > "$USER_BACKUP"
import json
print(json.dumps({
  "username": "$USERNAME",
  "entity_name": "$ENTITY_NAME",
  "entity_id": "$ENTITY_ID",
  "policy": "$POLICIES",
  "policies": "$POLICIES",
  "ssh_enabled": "$SSH_ENABLED" == "true",
  "password_stored_in_kv": False
}, indent=2))
PY
chmod 600 "$USER_BACKUP"
echo "  Local metadata backup: $USER_BACKUP"
echo "OpenBao user creation complete."
  )
}

command_openbao_create_approle() {
  (
# Create or update OpenBao AppRoles with short-lived, single-use wrapped SecretIDs.

set -Eeuo pipefail

BACKUP_DIR="${OPENBAO_BACKUP_DIR}"
TOKEN_TTL="30m"
TOKEN_MAX_TTL="2h"
SECRET_ID_TTL="30m"
WRAP_TTL="5m"

usage() {
  cat <<USAGE
Usage:
  scripts/homelab openbao create-approle <role-name> <policy> [options]

Options:
  --token-ttl=<duration>       Default: 30m
  --token-max-ttl=<duration>   Default: 2h
  --secret-id-ttl=<duration>   Default: 30m
  --wrap-ttl=<duration>        Default: 5m
USAGE
}

if [ $# -lt 2 ]; then
  usage
  exit 1
fi

ROLE_NAME="$1"
POLICY="$2"
shift 2

while [ $# -gt 0 ]; do
  case "$1" in
    --token-ttl=*) TOKEN_TTL="${1#*=}" ;;
    --token-max-ttl=*) TOKEN_MAX_TTL="${1#*=}" ;;
    --secret-id-ttl=*) SECRET_ID_TTL="${1#*=}" ;;
    --wrap-ttl=*) WRAP_TTL="${1#*=}" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
  shift
done

if ! [[ "$ROLE_NAME" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "ERROR: Role name must match ^[A-Za-z0-9._-]+$" >&2
  exit 1
fi

if ! [[ "$POLICY" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "ERROR: Policy must match ^[A-Za-z0-9._-]+$" >&2
  exit 1
fi

mkdir -p "$BACKUP_DIR/approles"

ROOT_TOKEN="$(openbao::load_root_token)"


if ! kubectl get pod "$OPENBAO_POD" -n "$OPENBAO_NS" >/dev/null 2>&1; then
  echo "ERROR: OpenBao pod '$OPENBAO_POD' not found in namespace '$OPENBAO_NS'." >&2
  exit 1
fi

kubectl wait --for=condition=Ready "pod/${OPENBAO_POD}" -n "$OPENBAO_NS" --timeout=300s >/dev/null
openbao::exec token lookup

if ! openbao::exec_quiet auth list -format=json | python3 -c "import json,sys; print('approle/' in json.load(sys.stdin))" 2>/dev/null | grep -q True; then
  echo "ERROR: approle auth is not enabled. Run bootstrap first." >&2
  exit 1
fi

if ! openbao::exec policy read "$POLICY"; then
  echo "ERROR: Policy '$POLICY' does not exist." >&2
  exit 1
fi

echo "=== Ensuring AppRole '$ROLE_NAME' ==="
openbao::exec write auth/approle/role/"${ROLE_NAME}" \
  "token_policies=${POLICY}" \
  "token_ttl=${TOKEN_TTL}" \
  "token_max_ttl=${TOKEN_MAX_TTL}" \
  "secret_id_ttl=${SECRET_ID_TTL}" \
  secret_id_num_uses=1 >/dev/null

echo "  Role configured with policy: $POLICY"
ROLE_ID="$(openbao::exec read -field=role_id auth/approle/role/"$ROLE_NAME"/role-id)"
WRAP_JSON="$(openbao::exec write -format=json -wrap-ttl="$WRAP_TTL" -f auth/approle/role/"$ROLE_NAME"/secret-id)"
WRAPPING_TOKEN="$(printf '%s\n' "$WRAP_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['wrap_info']['token'])")"
WRAPPING_ACCESSOR="$(printf '%s\n' "$WRAP_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['wrap_info'].get('accessor',''))")"

OUTPUT_FILE="$BACKUP_DIR/approles/${ROLE_NAME}.json"
python3 - <<PY > "$OUTPUT_FILE"
import json
print(json.dumps({
  "role_name": "$ROLE_NAME",
  "policy": "$POLICY",
  "role_id": "$ROLE_ID",
  "wrapped_secret_id_token": "$WRAPPING_TOKEN",
  "wrapped_secret_id_accessor": "$WRAPPING_ACCESSOR",
  "wrap_ttl": "$WRAP_TTL",
  "secret_id_ttl": "$SECRET_ID_TTL",
  "secret_id_num_uses": 1,
  "token_ttl": "$TOKEN_TTL",
  "token_max_ttl": "$TOKEN_MAX_TTL",
  "secret_id_stored_in_kv": False
}, indent=2))
PY
chmod 600 "$OUTPUT_FILE"

echo "  RoleID and wrapped SecretID saved to: $OUTPUT_FILE"
echo "  SecretID is response-wrapped. Unwrap within $WRAP_TTL."
echo "OpenBao AppRole creation complete."
  )
}

command="${1:-}"
[[ $# -gt 0 ]] && shift
case "$command" in
  bootstrap) command_openbao_bootstrap "$@" ;;
  policies) command_openbao_policies "$@" ;;
  status) command_openbao_status "$@" ;;
  create-user) command_openbao_create_user "$@" ;;
  create-approle) command_openbao_create_approle "$@" ;;
  *) echo "Unknown openbao command: $command" >&2; exit 2 ;;
esac
