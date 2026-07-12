#!/usr/bin/env bash
# Apply OpenBao policy-as-code files from the explicit policies/openbao registry.
#
# This script makes the repo the source of truth for OpenBao policies.
# It is safe to re-run: bao policy write overwrites policies atomically,
# identity entities are updated in place, and auth roles are overwritten.
#
# Usage:
#   bash scripts/openbao/apply-policies.sh
#
# Optional:
#   OPENBAO_TOKEN=<token> bash scripts/openbao/apply-policies.sh
#   GITHUB_REPOSITORY=owner/repo bash scripts/openbao/apply-policies.sh --enable-jwt

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck source=scripts/lib/common.sh
source "${PROJECT_ROOT}/scripts/lib/common.sh"
common::load_config "${PROJECT_ROOT}/config.env"
# shellcheck source=scripts/lib/openbao.sh
source "${PROJECT_ROOT}/scripts/lib/openbao.sh"

POLICY_DIR="${PROJECT_ROOT}/policies/openbao"
ENABLE_JWT="false"
SSH_ROLE_NAME="admin"
SSH_ALLOWED_USERS="*"
SSH_DEFAULT_USER="ubuntu"

# Explicit policy registry.
# Format: policy_name|relative_policy_file
# Keep this explicit so nested policy directories do not automatically grant access.
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

# Kubernetes auth/entity mapping table.
# Format: policy_name|namespace|service_account|create_kubernetes_role|create_identity_alias
#
# Keep this explicit. A policy file alone does not imply a Kubernetes principal.
# CI/CD uses optional GitHub OIDC JWT auth for ci-deployer; the Kubernetes role is
# retained here for clusters that also run an in-cluster ci-deployer service account.
POLICY_MAPPINGS=(
  "k8s-eso-reader|external-secrets|external-secrets|true|true"
  "app-demo|demo|default|true|true"
  "app-tailscale-operator|tailscale|operator|true|true"
  "ci-deployer|flux-system|ci-deployer|true|true"
  "system-admin|kube-system|headlamp-admin|true|true"
)

if [ "${1:-}" = "--enable-jwt" ]; then
  ENABLE_JWT="true"
fi


require_file() {
  common::require_file "$1"
}

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
    require_file "$POLICY_DIR/$relative_path"
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
  echo "  Run with: GITHUB_REPOSITORY=owner/repo bash scripts/openbao/apply-policies.sh --enable-jwt"
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
