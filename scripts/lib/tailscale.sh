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
TAILSCALE_BACKUP_DIR="$(common::abs_path "${TAILSCALE_BACKUP_DIR}")"

tailscale::operator_manifest_url() {
  printf 'https://raw.githubusercontent.com/tailscale/tailscale/%s/cmd/k8s-operator/deploy/manifests/operator.yaml\n' "${TAILSCALE_OPERATOR_VERSION}"
}

tailscale::ensure_namespace() {
  k8s::ensure_namespace "${TAILSCALE_NAMESPACE}"
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

tailscale::validate_identity_file() {
  local backup_file="$1"
  [[ -s "${backup_file}" ]] || common::die "Required Tailscale operator identity backup is missing or empty: ${backup_file}"
  python3 - "${backup_file}" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
keys = [k for k in (d.get('data') or {}) if k.startswith(('_machinekey', '_current-profile', 'profile-'))]
if not keys:
    raise SystemExit('operator identity backup lacks required identity keys')
PY
}

tailscale::restore_operator_identity() {
  local backup_file="$1"
  tailscale::validate_identity_file "${backup_file}"
  ! k8s::deployment_exists "${TAILSCALE_NAMESPACE}" "${TAILSCALE_OPERATOR_DEPLOYMENT}" || common::die "Refusing to restore identity after the Tailscale operator has started."
  python3 - "${backup_file}" <<'PY' | kubectl apply -f -
import json, sys
d = json.load(open(sys.argv[1]))
m = d.setdefault('metadata', {})
for key in ('creationTimestamp','resourceVersion','uid','managedFields','selfLink','ownerReferences'):
    m.pop(key, None)
m['namespace'] = 'tailscale'
d.pop('status', None)
json.dump(d, sys.stdout)
PY
  k8s::secret_exists "${TAILSCALE_NAMESPACE}" "${TAILSCALE_OPERATOR_SECRET}" || common::die "Tailscale operator identity restore did not create the expected Secret."
  log::success "Tailscale operator identity restored before startup."
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

  log::error "No Tailscale proxy pods found after waiting."
  return 1
}

tailscale::configure_serve() {
  "${COMMON_REPO_ROOT}/scripts/tailscale/configure-serve.sh"
}


tailscale::install_full() {
  local identity_backup="${1:-}"
  tailscale::ensure_namespace

  if [[ -n "${identity_backup}" ]]; then
    tailscale::restore_operator_identity "${identity_backup}"
  elif [[ -d "${TAILSCALE_BACKUP_DIR}" ]] && ! k8s::secret_exists "${TAILSCALE_NAMESPACE}" "${TAILSCALE_OPERATOR_SECRET}"; then
    common::die "Tailscale backups exist under ${TAILSCALE_BACKUP_DIR}, but no operator identity is restored. Use make recover BACKUP_DIR=<path>."
  fi

  tailscale::ensure_oauth_secret
  tailscale::install_operator

  log::info "Waiting for Tailscale proxy pods to be ready."
  tailscale::wait_proxy_pods 30 5

  log::info "Configuring Tailscale Serve on proxy pods."
  tailscale::configure_serve
}
