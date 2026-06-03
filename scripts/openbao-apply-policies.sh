#!/usr/bin/env bash
# Apply OpenBao policy-as-code files from policies/openbao/*.hcl.
#
# This script makes the repo the source of truth for OpenBao policies.
# It is safe to re-run: bao policy write overwrites policies atomically,
# identity entities are updated in place, and auth roles are overwritten.
#
# Usage:
#   bash scripts/openbao-apply-policies.sh
#
# Optional:
#   OPENBAO_TOKEN=<token> bash scripts/openbao-apply-policies.sh
#   GITHUB_REPOSITORY=owner/repo bash scripts/openbao-apply-policies.sh --enable-jwt

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${SCRIPT_DIR}/.."
POLICY_DIR="${PROJECT_ROOT}/policies/openbao"
BACKUP_DIR="${PROJECT_ROOT}/.runtime-backups/openbao"
INIT_JSON="${PROJECT_ROOT}/openbao-init.json"
OPENBAO_POD="openbao-0"
OPENBAO_NS="openbao"
REMOTE_POLICY_DIR="/tmp/openbao-policies"
ENABLE_JWT="false"
SSH_ROLE_NAME="admin"
SSH_ALLOWED_USERS="*"
SSH_DEFAULT_USER="ubuntu"

# Kubernetes auth/entity mapping table.
# Format: policy_name|namespace|service_account|create_kubernetes_role|create_identity_alias
#
# Keep this explicit. A policy file alone does not imply a Kubernetes principal.
# CI/CD uses optional GitHub OIDC JWT auth for ci-deployer; the Kubernetes role is
# retained here for clusters that also run an in-cluster ci-deployer service account.
POLICY_MAPPINGS=(
  "eso-reader|external-secrets|external-secrets|true|true"
  "app-demo|demo|default|true|true"
  "tailscale-operator|tailscale|operator|true|true"
  "ci-deployer|flux-system|ci-deployer|true|true"
  "admin|kube-system|headlamp-admin|true|true"
)

if [ "${1:-}" = "--enable-jwt" ]; then
  ENABLE_JWT="true"
fi

_bao_exec() {
  kubectl exec -n "$OPENBAO_NS" "$OPENBAO_POD" -- sh -c "
    export BAO_ADDR='http://127.0.0.1:8200'
    export BAO_TOKEN='${ROOT_TOKEN}'
    $*"
}

_bao_exec_quiet() {
  _bao_exec "$@" 2>/dev/null || true
}

require_file() {
  if [ ! -f "$1" ]; then
    echo "ERROR: Required file not found: $1"
    exit 1
  fi
}

load_root_token() {
  if [ -n "${OPENBAO_TOKEN:-}" ]; then
    printf '%s' "$OPENBAO_TOKEN"
    return
  fi

  if [ -f "$BACKUP_DIR/root-token.txt" ]; then
    tr -d '\n' < "$BACKUP_DIR/root-token.txt"
    return
  fi

  if [ -f "$INIT_JSON" ]; then
    python3 - <<PY
import json
from pathlib import Path
print(json.loads(Path("$INIT_JSON").read_text())["root_token"], end="")
PY
    return
  fi

  echo "ERROR: OpenBao token not provided." >&2
  echo "Set OPENBAO_TOKEN, restore $BACKUP_DIR/root-token.txt, or provide $INIT_JSON." >&2
  exit 1
}

policy_exists_in_repo() {
  [ -f "$POLICY_DIR/$1.hcl" ]
}

ensure_entity_and_alias() {
  local policy="$1"
  local namespace="$2"
  local service_account="$3"
  local create_alias="$4"
  local entity_id
  local accessor
  local alias_name

  if _bao_exec "bao read identity/entity/name/'$policy' >/dev/null 2>&1"; then
    entity_id=$(_bao_exec "bao read -field=id identity/entity/name/'$policy'")
    _bao_exec "bao write identity/entity/id/'$entity_id' \
      policies='$policy' \
      metadata=managed_by='openbao-apply-policies' \
      metadata=policy='$policy' \
      metadata=service_account_namespace='$namespace' \
      metadata=service_account_name='$service_account'" >/dev/null
  else
    entity_id=$(_bao_exec "bao write -field=id identity/entity \
      name='$policy' \
      policies='$policy' \
      metadata=managed_by='openbao-apply-policies' \
      metadata=policy='$policy' \
      metadata=service_account_namespace='$namespace' \
      metadata=service_account_name='$service_account'")
  fi

  echo "  Ensured entity: identity/entity/name/$policy"

  if [ "$create_alias" = "true" ]; then
    accessor=$(_bao_exec "bao read -field=accessor sys/auth/kubernetes")
    alias_name="system:serviceaccount:${namespace}:${service_account}"
    _bao_exec "bao write identity/entity-alias \
      name='$alias_name' \
      canonical_id='$entity_id' \
      mount_accessor='$accessor'" >/dev/null || true
    echo "  Ensured alias: $alias_name"
  fi
}

ensure_kubernetes_role() {
  local policy="$1"
  local namespace="$2"
  local service_account="$3"

  _bao_exec "bao write auth/kubernetes/role/'$policy' \
    bound_service_account_names='$service_account' \
    bound_service_account_namespaces='$namespace' \
    policies='$policy' \
    ttl=1h" >/dev/null

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

require_file "$POLICY_DIR/admin.hcl"
require_file "$POLICY_DIR/eso-reader.hcl"
require_file "$POLICY_DIR/ci-deployer.hcl"
require_file "$POLICY_DIR/app-demo.hcl"
require_file "$POLICY_DIR/tailscale-operator.hcl"

ROOT_TOKEN="$(load_root_token)"

# Verify authentication without printing or storing the token in OpenBao CLI config.
_bao_exec "bao token lookup >/dev/null"
echo "Authenticated to OpenBao."
echo ""

echo "=== Copying policy files into OpenBao pod ==="
_bao_exec "rm -rf '$REMOTE_POLICY_DIR' && mkdir -p '$REMOTE_POLICY_DIR'"
kubectl cp "$POLICY_DIR/." "${OPENBAO_NS}/${OPENBAO_POD}:${REMOTE_POLICY_DIR}"
echo "  Copied policies/openbao/*.hcl to ${OPENBAO_POD}:${REMOTE_POLICY_DIR}"
echo ""

echo "=== Applying policies from repo ==="
while IFS= read -r policy_file; do
  policy="$(basename "$policy_file" .hcl)"
  _bao_exec "bao policy write '$policy' '${REMOTE_POLICY_DIR}/${policy}.hcl'" >/dev/null
  echo "  Applied policy: $policy"
done < <(find "$POLICY_DIR" -maxdepth 1 -type f -name '*.hcl' | sort)
echo ""

echo "=== Ensuring mapped Kubernetes roles, entities, and aliases ==="
for mapping in "${POLICY_MAPPINGS[@]}"; do
  IFS='|' read -r policy namespace service_account create_role create_alias <<< "$mapping"

  if ! policy_exists_in_repo "$policy"; then
    echo "  Skipping mapping for '$policy': $POLICY_DIR/$policy.hcl not found."
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

if _bao_exec_quiet "bao secrets list -format=json" | python3 -c "import json,sys; d=json.load(sys.stdin); print('ssh-client-signer/' in d)" 2>/dev/null | grep -q True; then
  _bao_exec "bao write ssh-client-signer/roles/'$SSH_ROLE_NAME' \
    algorithm_signer='rsa-sha2-256' \
    allow_user_certificates=true \
    allowed_users='$SSH_ALLOWED_USERS' \
    default_user='$SSH_DEFAULT_USER' \
    key_type='ca' \
    ttl='30m'" >/dev/null
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
  if _bao_exec_quiet "bao auth list -format=json" | python3 -c "import json,sys; d=json.load(sys.stdin); print('jwt/' in d)" 2>/dev/null | grep -q True; then
    echo "  JWT auth already enabled."
  else
    _bao_exec "bao auth enable jwt"
    echo "  Enabled JWT auth."
  fi

  _bao_exec "bao write auth/jwt/config \
    oidc_discovery_url='https://token.actions.githubusercontent.com' \
    bound_issuer='https://token.actions.githubusercontent.com'" >/dev/null

  BOUND_CLAIMS="{\"sub\":\"repo:${GITHUB_REPOSITORY}:ref:refs/tags/v*\"}"
  _bao_exec "bao write auth/jwt/role/ci-deployer \
    role_type='jwt' \
    user_claim='sub' \
    bound_claims_type='glob' \
    bound_claims='${BOUND_CLAIMS}' \
    policies='ci-deployer' \
    ttl='15m'" >/dev/null
  echo "  Ensured role: auth/jwt/role/ci-deployer for repo ${GITHUB_REPOSITORY} tag releases."
  echo ""
else
  echo "=== Skipping GitHub OIDC JWT auth ==="
  echo "  Run with: GITHUB_REPOSITORY=owner/repo bash scripts/openbao-apply-policies.sh --enable-jwt"
  echo ""
fi

echo "=== Verification ==="
echo "Policies:"
_bao_exec "bao policy list"
echo ""
echo "Kubernetes roles:"
_bao_exec "bao list auth/kubernetes/role"
echo ""
echo "Entities:"
_bao_exec "bao list identity/entity/name"
echo ""
echo "OpenBao policy-as-code apply complete."
