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
set -eo pipefail

# configure-tailscale-serve.sh — Configures 'tailscale serve' on all Tailscale
# Kubernetes Operator proxy pods. The operator (as of v1.96) does not always
# configure serve automatically, causing HTTPS connections to fail with
# ERR_CONNECTION_TIMED_OUT from tailnet clients.
#
# This script is idempotent — safe to run multiple times.
# It should be run after initial setup and any time proxy pods restart.

echo "=== Configuring tailscale serve on proxy pods ==="

# Find all proxy pods managed by the tailscale operator
PROXY_PODS=$(kubectl get pods -n tailscale \
  -l tailscale.com/managed=true,tailscale.com/parent-resource-type=svc \
  -o json 2>/dev/null | python3 -c "
import sys, json
pods = json.load(sys.stdin).get('items', [])
for pod in pods:
    name = pod['metadata']['name']
    # Skip operator pod
    if name.startswith('operator-'):
        continue
    print(name)
" 2>/dev/null)

if [ -z "$PROXY_PODS" ]; then
  echo "No Tailscale proxy pods found. Nothing to configure."
  exit 0
fi

echo "Found proxy pods:"
echo "$PROXY_PODS" | while read -r pod; do echo "  - $pod"; done

CONFIGURED=0
SKIPPED=0
FAILED=0

for POD in $PROXY_PODS; do
  echo ""
  echo "--- Checking $POD ---"

  # Read current Serve configuration before deciding whether an update is needed.
  if ! SERVE_STATUS=$(kubectl exec -n tailscale "$POD" -c tailscale -- tailscale serve status 2>/dev/null); then
    SERVE_STATUS=""
  fi

  echo "  Determining backend URL..."

  DEST_IP=$(kubectl get pod -n tailscale "$POD" -o json | python3 -c "import json,sys; d=json.load(sys.stdin); print(next((e.get('value','') for c in d['spec'].get('containers',[]) if c.get('name')=='tailscale' for e in c.get('env',[]) if e.get('name')=='TS_DEST_IP'),''))")

  if [ -z "$DEST_IP" ]; then
    echo "  ✗ Could not determine TS_DEST_IP for $POD. Skipping."
    FAILED=$((FAILED + 1))
    continue
  fi

  # Get the parent service name and namespace
  PARENT_SVC=$(kubectl get pod -n tailscale "$POD" \
    -o jsonpath='{.metadata.labels.tailscale\.com/parent-resource}' 2>/dev/null || true)
  PARENT_NS=$(kubectl get pod -n tailscale "$POD" \
    -o jsonpath='{.metadata.labels.tailscale\.com/parent-resource-ns}' 2>/dev/null || true)

  if [ -z "$PARENT_SVC" ] || [ -z "$PARENT_NS" ]; then
    echo "  ✗ Could not determine parent service for $POD. Skipping."
    FAILED=$((FAILED + 1))
    continue
  fi

  # Pick an HTTP-compatible service port for Tailscale Serve.
  # Prefer explicit web/management ports before falling back to the first port.
  # Return both scheme and port so HTTPS-only backends like OpenBao are not
  # incorrectly contacted over plaintext HTTP.
  if ! BACKEND_TARGET=$(kubectl get svc -n "$PARENT_NS" "$PARENT_SVC" -o json | python3 -c "
import json, sys
ports = json.load(sys.stdin).get('spec', {}).get('ports', [])
def classify(p):
    name = str(p.get('name', '')).lower()
    proto = str(p.get('appProtocol', '')).lower()
    if proto in ('https', 'kubernetes.io/https') or name == 'https' or 'https' in name:
        return 'https'
    if proto in ('http', 'kubernetes.io/http', 'kubernetes.io/ws', 'kubernetes.io/h2c') or name in ('http','web','ui','management') or name.startswith('http-'):
        return 'http'
    return None
explicit = [(classify(p), p.get('port')) for p in ports if classify(p)]
if len(explicit) == 1:
    print(*explicit[0])
elif len(explicit) > 1:
    raise SystemExit('ambiguous HTTP service ports')
elif len(ports) == 1:
    raise SystemExit('single service port lacks explicit HTTP semantics')
else:
    raise SystemExit('no unambiguous HTTP service port')
"); then
    echo "  ✗ Service $PARENT_NS/$PARENT_SVC has no unambiguous HTTP backend."
    FAILED=$((FAILED + 1))
    continue
  fi

  BACKEND_SCHEME=${BACKEND_TARGET%% *}
  TARGET_PORT=${BACKEND_TARGET##* }

  if [ -z "$TARGET_PORT" ]; then
    echo "  ✗ Could not determine target port for $PARENT_SVC in $PARENT_NS. Skipping."
    FAILED=$((FAILED + 1))
    continue
  fi

  BACKEND_URL="${BACKEND_SCHEME}://${DEST_IP}:${TARGET_PORT}"
  echo "  Backend: $BACKEND_URL"

  if echo "$SERVE_STATUS" | grep -q "$BACKEND_URL"; then
    echo "  ✓ Already configured:"
    while IFS= read -r line; do echo "    $line"; done <<< "$SERVE_STATUS"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  if echo "$SERVE_STATUS" | grep -q "https://"; then
    echo "  Existing serve config differs; updating:"
    while IFS= read -r line; do echo "    $line"; done <<< "$SERVE_STATUS"
  fi

  # Configure tailscale serve
  echo "  Configuring tailscale serve..."
  if ! RESULT=$(kubectl exec -n tailscale "$POD" -c tailscale -- \
    tailscale serve --bg --set-path / "$BACKEND_URL" 2>&1); then
    echo "  ✗ Failed to configure serve:"
    while IFS= read -r line; do echo "    $line"; done <<< "$RESULT"
    FAILED=$((FAILED + 1))
    continue
  fi
  if SERVE_STATUS=$(kubectl exec -n tailscale "$POD" -c tailscale -- tailscale serve status 2>/dev/null) && awk -v target="$BACKEND_URL" '{for (i=1;i<=NF;i++) if ($i == target) found=1} END {exit !found}' <<< "$SERVE_STATUS"; then
    echo "  ✓ Serve configured successfully."
    CONFIGURED=$((CONFIGURED + 1))
  else
    echo "  ✗ Serve status does not contain exact backend: $BACKEND_URL"
    FAILED=$((FAILED + 1))
  fi
done

echo ""
echo "=== Summary ==="
echo "  Configured: $CONFIGURED"
echo "  Skipped (already configured): $SKIPPED"
echo "  Failed: $FAILED"

if [ $FAILED -gt 0 ]; then
  exit 1
fi
}

tailscale::deploy_serve_watcher() {
  [[ -s "${TAILSCALE_SERVE_WATCHER_MANIFEST}" ]] || common::die "Tailscale Serve watcher manifest missing: ${TAILSCALE_SERVE_WATCHER_MANIFEST}"
  kubectl apply -f "${TAILSCALE_SERVE_WATCHER_MANIFEST}"
  log::success "Tailscale Serve watcher deployed."
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
