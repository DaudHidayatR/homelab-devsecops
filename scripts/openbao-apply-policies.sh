#!/usr/bin/env bash
# Apply OpenBao policy-as-code files from policies/openbao/*.hcl.
#
# This script makes the repo the source of truth for OpenBao policies.
# It is safe to re-run: bao policy write overwrites policies atomically.
#
# Usage:
#   bash scripts/openbao-apply-policies.sh
#
# Optional:
#   GITHUB_REPOSITORY=owner/repo bash scripts/openbao-apply-policies.sh --enable-jwt

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${SCRIPT_DIR}/.."
POLICY_DIR="${PROJECT_ROOT}/policies/openbao"
BACKUP_DIR="${PROJECT_ROOT}/.runtime-backups/openbao"
OPENBAO_POD="openbao-0"
OPENBAO_NS="openbao"
ESO_NS="external-secrets"
ESO_SA="external-secrets"
REMOTE_POLICY_DIR="/tmp/openbao-policies"
ENABLE_JWT="false"

if [ "${1:-}" = "--enable-jwt" ]; then
  ENABLE_JWT="true"
fi

_bao_exec() {
  kubectl exec -n "$OPENBAO_NS" "$OPENBAO_POD" -- sh -c "
    export BAO_ADDR='http://127.0.0.1:8200'
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

echo "=== OpenBao Policy-as-Code Apply ==="
echo ""

if ! kubectl get pod "$OPENBAO_POD" -n "$OPENBAO_NS" &>/dev/null; then
  echo "ERROR: OpenBao pod '$OPENBAO_POD' not found in namespace '$OPENBAO_NS'."
  echo "Deploy the cluster first: make up"
  exit 1
fi

kubectl wait --for=condition=Ready "pod/${OPENBAO_POD}" -n "$OPENBAO_NS" --timeout=300s

require_file "$BACKUP_DIR/root-token.txt"
require_file "$POLICY_DIR/admin.hcl"
require_file "$POLICY_DIR/eso-reader.hcl"
require_file "$POLICY_DIR/ci-deployer.hcl"
require_file "$POLICY_DIR/app-demo.hcl"
require_file "$POLICY_DIR/tailscale-operator.hcl"

ROOT_TOKEN=$(cat "$BACKUP_DIR/root-token.txt")
_bao_exec "bao login '$ROOT_TOKEN'" >/dev/null

echo "Authenticated to OpenBao."
echo ""

echo "=== Copying policy files into OpenBao pod ==="
_bao_exec "rm -rf '$REMOTE_POLICY_DIR' && mkdir -p '$REMOTE_POLICY_DIR'"
kubectl cp "$POLICY_DIR/." "${OPENBAO_NS}/${OPENBAO_POD}:${REMOTE_POLICY_DIR}"
echo "  Copied policies/openbao/*.hcl to ${OPENBAO_POD}:${REMOTE_POLICY_DIR}"
echo ""

echo "=== Applying policies ==="
for policy in admin eso-reader ci-deployer app-demo tailscale-operator; do
  _bao_exec "bao policy write '$policy' '${REMOTE_POLICY_DIR}/${policy}.hcl'"
  echo "  Applied policy: $policy"
done
echo ""

echo "=== Ensuring Kubernetes auth role for ESO ==="
_bao_exec "bao write auth/kubernetes/role/eso-reader \
  bound_service_account_names='$ESO_SA' \
  bound_service_account_namespaces='$ESO_NS' \
  policies=eso-reader \
  ttl=1h"
echo "  Ensured role: auth/kubernetes/role/eso-reader"
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
    bound_issuer='https://token.actions.githubusercontent.com'"

  BOUND_CLAIMS="{\"sub\":\"repo:${GITHUB_REPOSITORY}:ref:refs/tags/v*\"}"
  _bao_exec "bao write auth/jwt/role/ci-deployer \
    role_type='jwt' \
    user_claim='sub' \
    bound_claims_type='glob' \
    bound_claims='${BOUND_CLAIMS}' \
    policies='ci-deployer' \
    ttl='15m'"
  echo "  Ensured role: auth/jwt/role/ci-deployer for repo ${GITHUB_REPOSITORY} tag releases."
  echo ""
else
  echo "=== Skipping GitHub OIDC JWT auth ==="
  echo "  Run with: GITHUB_REPOSITORY=owner/repo bash scripts/openbao-apply-policies.sh --enable-jwt"
  echo ""
fi

echo "=== Verification ==="
_bao_exec "bao policy list"
echo ""
echo "OpenBao policy-as-code apply complete."
