#!/usr/bin/env bash
# Shared Tailscale helpers for infra/kind scripts.
#
# Ownership contract (architecture audit v2 remediation, 2026-08-31):
# Flux declares and owns the Tailscale operator installation via the
# platform/tailscale HelmRelease. The shell layer NEVER applies upstream
# operator manifests and NEVER patches the operator deployment; it only
# delivers the OAuth Secret out-of-band and verifies the rollout.
#

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
: "${TAILSCALE_BACKUP_DIR:=${COMMON_REPO_ROOT}/.runtime-backups/tailscale}"
TAILSCALE_BACKUP_DIR="$(common::abs_path "${TAILSCALE_BACKUP_DIR}")"

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

# The Flux-managed HelmRelease mounts this Secret, so it must exist before
# the platform layer reconciles. Delivery order (decision 2026-08-31):
#   1. SOPS-encrypted source tailscale/operator-oauth.enc.yaml (preferred)
#   2. TAILSCALE_CLIENT_ID / TAILSCALE_CLIENT_SECRET env (first bootstrap)
# Returns 1 when neither source is available. Callers must either fail or
# explicitly implement a Tailscale-disabled mode; silently continuing leaves
# the Flux platform layer predictably unready.
tailscale::ensure_deploy_secret() {
  tailscale::ensure_namespace
  if k8s::secret_exists "${TAILSCALE_NAMESPACE}" "${TAILSCALE_OPERATOR_OAUTH_SECRET}"; then
    return 0
  fi

  local enc_file="${COMMON_REPO_ROOT}/tailscale/operator-oauth.enc.yaml"
  if [[ -s "${enc_file}" ]] && command -v sops >/dev/null 2>&1; then
    local plain
    plain="$(mktemp "${TMPDIR:-/tmp}/operator-oauth.XXXXXX")"
    chmod 0600 "${plain}"
    if sops -d "${enc_file}" >"${plain}" 2>/dev/null; then
      kubectl apply -f "${plain}" >/dev/null
      rm -f "${plain}"
      log::success "Applied ${TAILSCALE_NAMESPACE}/${TAILSCALE_OPERATOR_OAUTH_SECRET} from the SOPS-encrypted source."
      return 0
    fi
    rm -f "${plain}"
    log::warn "sops decryption failed for tailscale/operator-oauth.enc.yaml (placeholder recipient?); falling back to environment credentials."
  elif [[ -s "${enc_file}" ]]; then
    log::warn "tailscale/operator-oauth.enc.yaml exists but sops is not installed; falling back to environment credentials."
  fi

  if [[ -n "${TAILSCALE_CLIENT_ID:-}" && -n "${TAILSCALE_CLIENT_SECRET:-}" ]]; then
    tailscale::ensure_oauth_secret
    return 0
  fi

  common::die "Tailscale is part of the declared platform but no OAuth credentials are available. Run 'make tailscale-encrypt' with a real age recipient, or set TAILSCALE_CLIENT_ID/TAILSCALE_CLIENT_SECRET for one bootstrap and then create the SOPS source."
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

tailscale::validate_oauth_file() {
  local backup_file="$1"
  [[ -s "${backup_file}" ]] || return 0  # absent or empty = optional; skipped by restore
  python3 - "${backup_file}" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
data = d.get('data') or {}
for key in ('client_id', 'client_secret'):
    if key not in data:
        raise SystemExit(f'operator-oauth backup lacks required key: {key}')
PY
}

# Proxy (ts-*) identities are intentionally NOT restored: the Tailscale
# operator names them with per-rebuild random suffixes and owns/recreates
# them. Emit a non-secret note when a backup directory contains proxy
# identity data so nobody mistakes all-secrets.json for a recovery input.
tailscale::note_excluded_proxy_identities() {
  local backup_dir="$1"
  local found=0 f
  if [[ -f "${backup_dir}/all-secrets.json" ]]; then
    found=1
  fi
  for f in "${backup_dir}"/ts-*; do
    [[ -e "${f}" ]] && found=1
  done
  if [[ "${found}" -eq 1 ]]; then
    log::info "Backup contains proxy identity data (all-secrets.json or ts-* Secrets). Proxy identities are not restored by design; proxy devices re-register after rebuild."
  fi
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

  log::warn "No Tailscale proxy pods found after waiting. Ingress-backed proxies appear once Flux reconciles the declared Ingresses; check 'kubectl get ingress -A'."
  return 1
}

tailscale::wait_operator() {
  k8s::wait_deployment_ready "${TAILSCALE_NAMESPACE}" "${TAILSCALE_OPERATOR_DEPLOYMENT}" "${1:-120s}"
}

# Verify the Flux-managed operator installation. The platform/tailscale
# HelmRelease is the single source of truth; applying upstream manifests or
# patching the deployment here would fight the Flux reconciler.
# Verify the Flux-managed operator installation. The platform/tailscale
# HelmRelease is the single source of truth; applying upstream manifests or
# patching the deployment here would fight the Flux reconciler.
tailscale::install_operator() {
  if [[ -z "$(kubectl get helmrelease tailscale-operator -n "${TAILSCALE_NAMESPACE}" -o name 2>/dev/null || true)" ]]; then
    common::die "HelmRelease tailscale-operator not found in namespace '${TAILSCALE_NAMESPACE}'. Flux owns the operator install: run 'make up' so the platform layer applies it, then rerun this verification."
  fi
  log::info "Verifying the Flux-managed Tailscale operator (HelmRelease tailscale-operator)."
  kubectl wait --for=condition=Ready helmrelease/tailscale-operator -n "${TAILSCALE_NAMESPACE}" --timeout=300s
  tailscale::wait_operator 180s
  log::success "Tailscale operator verified (Flux-owned install)."
}
