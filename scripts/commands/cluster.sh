#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

command_cluster_up() {
  (
# Deploy the full kind cluster and supporting DevSecOps components.

set -Eeuo pipefail

PROJECT_ROOT="$ROOT_DIR"

# shellcheck source=scripts/lib/common.sh
source "${PROJECT_ROOT}/scripts/lib/common.sh"
COMMON_REQUIRE_CONFIG=true common::load_config "${PROJECT_ROOT}/config.env"
ENV_GITHUB_USER="${GITHUB_USER-}"
ENV_GITHUB_TOKEN="${GITHUB_TOKEN-}"
[[ -z "${ENV_GITHUB_USER}" ]] || GITHUB_USER="${ENV_GITHUB_USER}"
[[ -z "${ENV_GITHUB_TOKEN}" ]] || GITHUB_TOKEN="${ENV_GITHUB_TOKEN}"
unset ENV_GITHUB_USER ENV_GITHUB_TOKEN
common::install_traps

# shellcheck source=scripts/lib/cluster.sh
source "${PROJECT_ROOT}/scripts/lib/cluster.sh"
# shellcheck source=scripts/lib/flux.sh
source "${PROJECT_ROOT}/scripts/lib/flux.sh"
# shellcheck source=scripts/lib/kubernetes.sh
source "${PROJECT_ROOT}/scripts/lib/kubernetes.sh"
# shellcheck source=scripts/lib/openbao.sh
source "${PROJECT_ROOT}/scripts/lib/openbao.sh"
# shellcheck source=scripts/lib/tailscale.sh
source "${PROJECT_ROOT}/scripts/lib/tailscale.sh"

DEPLOYMENT_MODE="not-started"
TAILSCALE_MODE="skipped"
OPENBAO_POST_SETUP_REQUIRED="yes"


tailscale::install_if_configured() {
  log::section "5. Verifying Tailscale operator (Flux-managed, optional)"
  # Ownership contract (audit v2, 2026-08-31): Flux owns the operator
  # install via platform/tailscale. The shell only delivers the OAuth
  # Secret (SOPS first, env fallback) and verifies the rollout.
  if tailscale::ensure_deploy_secret; then
    TAILSCALE_MODE="Flux-managed (credentials delivered)"
    tailscale::install_operator
  else
    TAILSCALE_MODE="skipped (no OAuth credentials; deliver via 'make tailscale-encrypt' or env)"
    log::warn "Tailscale credentials unavailable; the Flux-managed operator HelmRelease stays unready until delivered."
  fi
}

setup::print_preflight_notes() {
  log::section "2. Istio deployment"
  log::info "Istio will be deployed via Flux from kubernetes/clusters/homelab/platform/istio/."
}

setup::print_summary() {
  log::section "Setup Summary"
  cat <<MSG
Deployment mode: ${DEPLOYMENT_MODE}
Tailscale mode: ${TAILSCALE_MODE}
OpenBao post-setup required: ${OPENBAO_POST_SETUP_REQUIRED}

If this is a fresh OpenBao install, run these after the OpenBao pod is ready:
  kubectl wait --for=condition=Ready pod/${OPENBAO_POD} -n ${OPENBAO_NS} --timeout=300s
  scripts/homelab openbao bootstrap
MSG
}

main() {
  common::require_commands kind kubectl python3

  log::section "1. Creating kind cluster (rootless)"
  cluster::ensure_kind "${PROJECT_ROOT}/kubernetes/clusters/homelab/bootstrap/controllers/kind-cluster.yaml"

  setup::print_preflight_notes


  log::section "4. Bootstrapping Flux CD"
  flux::bootstrap_or_apply DEPLOYMENT_MODE

  kubectl wait --for=condition=Ready \
    kustomization/bootstrap \
    kustomization/cluster-resources \
    kustomization/platform \
    kustomization/openbao-config \
    kustomization/cluster-policies \
    kustomization/operations \
    kustomization/apps \
    -n flux-system --timeout=300s

  tailscale::install_if_configured
  setup::print_summary

  # SRP: access instructions live in their own script; setup ends at infrastructure readiness.
  command_cluster_info
}

main "$@"
  )
}

command_cluster_down() {
  (
set -euo pipefail
umask 077

PROJECT_ROOT="$ROOT_DIR"
# shellcheck source=/dev/null
source "${PROJECT_ROOT}/config.env"
# shellcheck source=scripts/lib/cluster.sh
source "${PROJECT_ROOT}/scripts/lib/cluster.sh"

cluster::validate_name

# shellcheck disable=SC2031 # Value may be loaded from config.env in this subshell.
BACKUP_ROOT="${TAILSCALE_BACKUP_DIR:-${PROJECT_ROOT}/.runtime-backups/tailscale}"
BACKUP_DIR="${BACKUP_ROOT}/$(date +%Y%m%d-%H%M%S)"
BACKUP_CREATED="false"

echo "=== Preparing to destroy kind cluster (rootless) ==="
echo "WARNING: This deletes Kubernetes runtime state. For normal app redeploys, use: make redeploy"
echo "WARNING: Deleting the cluster without restoring Tailscale state can create duplicate tailnet devices."

backup_secret() {
  local name="$1" required="$2" temp
  local target="${BACKUP_DIR}/${name}.json"
  temp="$(mktemp "${target}.tmp.XXXXXX")"
  chmod 0600 "$temp"
  if ! kubectl get secret "$name" -n tailscale -o json >"$temp"; then
    rm -f "$temp"
    [ "$required" = false ] || { echo "ERROR: required tailscale/$name Secret is missing" >&2; exit 1; }
    return 0
  fi
  python3 - "$temp" "$required" <<'PY'
import json, sys
p, required = sys.argv[1], sys.argv[2] == 'true'
d = json.load(open(p))
if required and not any(k.startswith(('_machinekey', '_current-profile', 'profile-')) for k in (d.get('data') or {})):
    raise SystemExit('required operator identity keys are missing')
PY
  mv "$temp" "$target"
}

if kubectl get namespace tailscale &>/dev/null; then
  echo "=== Backing up Tailscale Kubernetes state ==="
  install -d -m 0700 "$BACKUP_DIR"
  backup_secret operator true
  backup_secret operator-oauth false
  temp="$(mktemp "${BACKUP_DIR}/all-secrets.json.tmp.XXXXXX")"
  chmod 0600 "$temp"
  kubectl get secrets -n tailscale -o json >"$temp"
  python3 -m json.tool "$temp" >/dev/null
  mv "$temp" "${BACKUP_DIR}/all-secrets.json"
  BACKUP_CREATED="true"
  if [[ -n "${TAILSCALE_BACKUP_RESULT_FILE:-}" ]]; then
    printf '%s\n' "${BACKUP_DIR}" > "${TAILSCALE_BACKUP_RESULT_FILE}"
  fi
else
  echo "=== No tailscale namespace found; skipping Tailscale state backup ==="
fi

echo "=== Destroying kind cluster (rootless) ==="
kind delete cluster --name "$CLUSTER_NAME"

if [ "$BACKUP_CREATED" = "true" ]; then
  echo "=== Tailscale Backup Created ==="
  echo "Backup path: ${BACKUP_DIR}"
  echo "Before reinstalling the operator on a rebuilt cluster, restore it with:"
  echo "  scripts/homelab tailscale restore ${BACKUP_DIR}"
fi

echo "=== Teardown Complete! ==="
  )
}

command_cluster_recover() {
  (
set -euo pipefail

PROJECT_ROOT="$ROOT_DIR"
# shellcheck source=scripts/lib/common.sh
source "${PROJECT_ROOT}/scripts/lib/common.sh"
COMMON_REQUIRE_CONFIG=true common::load_config "${PROJECT_ROOT}/config.env"
# shellcheck source=scripts/lib/cluster.sh
source "${PROJECT_ROOT}/scripts/lib/cluster.sh"
# shellcheck source=scripts/lib/tailscale.sh
source "${PROJECT_ROOT}/scripts/lib/tailscale.sh"

BACKUP_DIR="${1:-}"
cluster::validate_name
common::require_commands kind kubectl python3

if cluster::exists; then
  result_file="$(mktemp)"
  trap 'rm -f "${result_file}"' EXIT
  TAILSCALE_BACKUP_RESULT_FILE="${result_file}" command_cluster_down
  [[ -s "${result_file}" ]] || common::die "Cluster destruction produced no Tailscale identity backup; refusing recovery."
  BACKUP_DIR="$(cat "${result_file}")"
else
  [[ -n "${BACKUP_DIR}" ]] || common::die "No cluster exists. Usage: $0 <validated-backup-directory>"
fi
tailscale::validate_identity_file "${BACKUP_DIR}/operator.json"

cluster::ensure_kind "${PROJECT_ROOT}/kubernetes/clusters/homelab/bootstrap/controllers/kind-cluster.yaml"
tailscale::ensure_namespace
command_tailscale_restore "${BACKUP_DIR}"
command_cluster_up
  )
}
command_tailscale_restore() {
  "${ROOT_DIR}/scripts/commands/tailscale.sh" restore "$@"
}

command_cluster_info() {
  (
set -eo pipefail

# show-access-info.sh — Post-setup access instructions
# Principle: SRP — this script has one reason to change: how users access services.
# setup.sh has one reason to change: infrastructure orchestration.

PROJECT_ROOT="$ROOT_DIR"
# shellcheck source=/dev/null
source "${PROJECT_ROOT}/config.env"

cat <<EOF
=== Setup Complete! ===
Check pod status with: kubectl get pods -n ${DEMO_NAMESPACE}

--- Tailscale Private Access ---
If TAILSCALE_CLIENT_ID and TAILSCALE_CLIENT_SECRET are set in config.env,
admin UIs are automatically available on your tailnet:
   Headlamp:  https://headlamp-kube-system.<tailnet>.ts.net
   OpenBao:   https://openbao-openbao.<tailnet>.ts.net

If Tailscale credentials are not configured, use legacy port-forward access below.

--- Legacy Port-Forward Access ---
To access Headlamp Web UI:
1. Run: kubectl port-forward -n kube-system service/headlamp 8080:80
2. Get your login token: kubectl create token headlamp-admin -n kube-system
3. Open http://localhost:8080 in your browser


To bootstrap OpenBao (single-node raft):
1. Run: kubectl port-forward -n openbao svc/openbao 8200:8200
2. Initialize once: kubectl exec -it -n openbao openbao-0 -- bao operator init -key-shares=1 -key-threshold=1
3. Unseal with the returned key: kubectl exec -it -n openbao openbao-0 -- bao operator unseal <unseal_key>
4. Open https://localhost:8200 in your browser (accept the self-signed certificate warning)
5. Back up the init output outside the cluster (root token + unseal key)
EOF
  )
}

command="${1:-}"
[[ $# -gt 0 ]] && shift
case "$command" in
  up) command_cluster_up "$@" ;;
  down) command_cluster_down "$@" ;;
  recover) command_cluster_recover "$@" ;;
  info) command_cluster_info "$@" ;;
  *) echo "Unknown cluster command: $command" >&2; exit 2 ;;
esac
