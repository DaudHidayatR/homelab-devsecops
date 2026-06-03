#!/usr/bin/env bash
# Shared Tailscale helpers for infra/kind scripts.

if [[ -n "${KIND_TAILSCALE_SH_LOADED:-}" ]]; then
  return 0
fi
KIND_TAILSCALE_SH_LOADED=1

# shellcheck source=scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
# shellcheck source=scripts/lib/kubernetes.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/kubernetes.sh"

: "${TAILSCALE_NAMESPACE:=tailscale}"
: "${TAILSCALE_OPERATOR_DEPLOYMENT:=operator}"
: "${TAILSCALE_OPERATOR_SECRET:=operator}"
: "${TAILSCALE_OPERATOR_OAUTH_SECRET:=operator-oauth}"
: "${TAILSCALE_OPERATOR_VERSION:=v1.96.4}"
: "${TAILSCALE_BACKUP_DIR:=${COMMON_REPO_ROOT}/.runtime-backups/tailscale}"
: "${TAILSCALE_SERVE_WATCHER_MANIFEST:=${COMMON_REPO_ROOT}/tailscale/serve-watcher.yaml}"
TAILSCALE_BACKUP_DIR="$(common::abs_path "${TAILSCALE_BACKUP_DIR}")"
TAILSCALE_SERVE_WATCHER_MANIFEST="$(common::abs_path "${TAILSCALE_SERVE_WATCHER_MANIFEST}")"

tailscale::operator_manifest_url() {
  printf 'https://raw.githubusercontent.com/tailscale/tailscale/%s/cmd/k8s-operator/deploy/manifests/operator.yaml\n' "${TAILSCALE_OPERATOR_VERSION}"
}

tailscale::ensure_namespace() {
  if ! k8s::namespace_exists "${TAILSCALE_NAMESPACE}"; then
    if [[ -d "${TAILSCALE_BACKUP_DIR}" ]]; then
      log::warn "${TAILSCALE_NAMESPACE} namespace is missing, but local Tailscale backups exist under: ${TAILSCALE_BACKUP_DIR}"
      log::warn "Restore a previous operator identity before continuing if you need to avoid duplicate Tailscale devices."
    fi
    k8s::ensure_namespace "${TAILSCALE_NAMESPACE}"
  fi
}

tailscale::ensure_oauth_secret() {
  if k8s::secret_exists "${TAILSCALE_NAMESPACE}" "${TAILSCALE_OPERATOR_OAUTH_SECRET}"; then
    return 0
  fi

  [[ -n "${TAILSCALE_CLIENT_ID:-}" ]] || common::die "TAILSCALE_CLIENT_ID is required to create ${TAILSCALE_OPERATOR_OAUTH_SECRET}."
  [[ -n "${TAILSCALE_CLIENT_SECRET:-}" ]] || common::die "TAILSCALE_CLIENT_SECRET is required to create ${TAILSCALE_OPERATOR_OAUTH_SECRET}."

  log::info "Creating Tailscale OAuth secret ${TAILSCALE_NAMESPACE}/${TAILSCALE_OPERATOR_OAUTH_SECRET}."
  kubectl create secret generic "${TAILSCALE_OPERATOR_OAUTH_SECRET}" \
    --namespace "${TAILSCALE_NAMESPACE}" \
    --from-literal=client_id="${TAILSCALE_CLIENT_ID}" \
    --from-literal=client_secret="${TAILSCALE_CLIENT_SECRET}"
}

tailscale::backup_operator_identity() {
  local output_file="$1"
  if k8s::secret_exists "${TAILSCALE_NAMESPACE}" "${TAILSCALE_OPERATOR_SECRET}"; then
    kubectl get secret "${TAILSCALE_OPERATOR_SECRET}" -n "${TAILSCALE_NAMESPACE}" -o json >"${output_file}"
    log::success "Backed up existing Tailscale operator identity."
  else
    log::warn "No existing ${TAILSCALE_NAMESPACE}/${TAILSCALE_OPERATOR_SECRET} identity Secret found."
    if [[ -d "${TAILSCALE_BACKUP_DIR}" ]]; then
      log::warn "Local backup root detected: ${TAILSCALE_BACKUP_DIR}"
    fi
  fi
}

tailscale::restore_operator_identity() {
  local backup_file="$1"
  [[ -s "${backup_file}" ]] || return 0

  local identity_keys
  identity_keys="$(python3 -c "
import json
with open('${backup_file}') as f:
    d = json.load(f)
keys = [k for k in d.get('data',{}) if k.startswith('_machinekey') or k.startswith('_current-profile') or k.startswith('profile-')]
print(' '.join(keys))" 2>/dev/null || true)"

  [[ -n "${identity_keys}" ]] || return 0

  log::info "Restoring Tailscale operator device identity to prevent duplicate devices."
  kubectl get secret "${TAILSCALE_OPERATOR_SECRET}" -n "${TAILSCALE_NAMESPACE}" -o json 2>/dev/null | python3 -c "
import json, sys
backup = json.load(open('${backup_file}'))
live = json.load(sys.stdin)
for k, v in backup.get('data', {}).items():
    if k.startswith('_machinekey') or k.startswith('_current-profile') or k.startswith('profile-'):
        live.setdefault('data', {})[k] = v
json.dump(live, sys.stdout)" | kubectl replace -f - 2>/dev/null || true
  log::success "Tailscale operator identity preserved."
}

tailscale::install_operator() {
  if k8s::deployment_exists "${TAILSCALE_NAMESPACE}" "${TAILSCALE_OPERATOR_DEPLOYMENT}"; then
    log::info "Tailscale operator already installed."
    return 0
  fi

  log::info "Installing Tailscale Kubernetes Operator (${TAILSCALE_OPERATOR_VERSION})."
  kubectl apply -f "$(tailscale::operator_manifest_url)"
  tailscale::wait_operator 120s
  log::success "Tailscale operator is ready."
}

tailscale::wait_operator() {
  k8s::wait_deployment_ready "${TAILSCALE_NAMESPACE}" "${TAILSCALE_OPERATOR_DEPLOYMENT}" "${1:-120s}"
}

tailscale::proxy_pods() {
  kubectl get pods -n "${TAILSCALE_NAMESPACE}" \
    -l tailscale.com/managed=true,tailscale.com/parent-resource-type=svc \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true
}

tailscale::wait_proxy_pods() {
  local attempts="${1:-30}"
  local delay="${2:-5}"
  local proxy_count

  for _i in $(seq 1 "${attempts}"); do
    proxy_count="$(tailscale::proxy_pods | grep -cv 'operator-' || true)"
    if [[ "${proxy_count}" -gt 0 ]]; then
      log::success "Found ${proxy_count} Tailscale proxy pod(s)."
      return 0
    fi
    sleep "${delay}"
  done

  log::warn "No Tailscale proxy pods found after waiting."
  return 0
}

tailscale::configure_serve() {
  "${COMMON_REPO_ROOT}/scripts/tailscale/configure-serve.sh"
}

tailscale::deploy_serve_watcher() {
  kubectl apply -f "${TAILSCALE_SERVE_WATCHER_MANIFEST}"
}

tailscale::install_full() {
  tailscale::ensure_namespace
  tailscale::ensure_oauth_secret

  local identity_backup
  common::mktemp_var identity_backup
  tailscale::backup_operator_identity "${identity_backup}"
  tailscale::install_operator
  tailscale::restore_operator_identity "${identity_backup}"

  log::info "Waiting for Tailscale proxy pods to be ready."
  tailscale::wait_proxy_pods 30 5

  log::info "Configuring Tailscale Serve on proxy pods."
  tailscale::configure_serve

  log::info "Deploying Tailscale Serve watcher."
  tailscale::deploy_serve_watcher
  log::success "Tailscale Serve watcher deployed."
}
