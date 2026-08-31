#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

command_tailscale_install() {
  (
# Verify the Flux-managed Tailscale Kubernetes Operator installation.
# Ownership contract (audit v2, 2026-08-31): Flux owns the install via the
# platform/tailscale HelmRelease; this command delivers the OAuth Secret
# (SOPS first, env fallback) and verifies the rollout. It never applies
# upstream manifests and never patches the deployment.

set -Eeuo pipefail

PROJECT_ROOT="$ROOT_DIR"

# shellcheck source=scripts/lib/common.sh
source "${PROJECT_ROOT}/scripts/lib/common.sh"
common::load_config "${PROJECT_ROOT}/config.env"
common::install_traps
# shellcheck source=scripts/lib/tailscale.sh
source "${PROJECT_ROOT}/scripts/lib/tailscale.sh"

usage() {
  cat <<'USAGE'
Usage:
  scripts/homelab tailscale install

Verify the Flux-managed Tailscale operator installation (HelmRelease
tailscale-operator). Deliver the operator-oauth Secret first via
'make tailscale-encrypt' (SOPS) or TAILSCALE_CLIENT_ID/TAILSCALE_CLIENT_SECRET
in config.env.
USAGE
}

while (($# > 0)); do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    *)
      common::die "Unknown argument: $1"
      ;;
  esac
  shift
done

main() {
  common::require_commands kubectl python3

  log::section "Verifying Tailscale Kubernetes Operator (Flux-managed)"
  if ! tailscale::ensure_deploy_secret; then
    common::die "Deliver ${TAILSCALE_NAMESPACE}/operator-oauth first: run 'make tailscale-encrypt' (SOPS flow) or set TAILSCALE_CLIENT_ID/TAILSCALE_CLIENT_SECRET in config.env, then rerun."
  fi

  tailscale::install_operator

  log::info "Waiting for Tailscale proxy pods to be ready."
  if ! tailscale::wait_proxy_pods 30 5; then
    log::warn "No proxy pods yet. Declare access via tailscale-class Ingresses (see kubernetes/clusters/homelab/apps/headlamp/ingress.yaml); proxies appear once Flux reconciles them."
  fi

  log::success "Tailscale operator verification complete."
  cat <<'MSG'
Tailnet access is declared with tailscale-class Ingresses. The operator serves
https://<service>-<namespace>.<tailnet>.ts.net for each Ingress.

For public internet access, add the annotation:
  tailscale.com/funnel: "true"
MSG
}

main "$@"
  )
}

command_tailscale_reset() {
  (
set -euo pipefail
umask 077

REPO_ROOT="$ROOT_DIR"
BACKUP_ROOT="${REPO_ROOT}/.runtime-backups/tailscale"
BACKUP_DIR="${BACKUP_ROOT}/reset-proxies-$(date +%Y%m%d-%H%M%S)"

if ! kubectl get namespace tailscale &>/dev/null; then
  echo "tailscale namespace does not exist. Nothing to reset."
  exit 0
fi

install -d -m 0700 "$BACKUP_DIR"
temp="$(mktemp "${BACKUP_DIR}/all-secrets.json.tmp.XXXXXX")"
chmod 0600 "$temp"
kubectl get secrets -n tailscale -o json > "$temp"
python3 - "$temp" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    doc = json.load(f)
if not isinstance(doc, dict) or doc.get('kind') != 'List':
    raise SystemExit('invalid Kubernetes SecretList backup')
PY
mv "$temp" "${BACKUP_DIR}/all-secrets.json"
echo "Backed up tailscale Secrets to: ${BACKUP_DIR}/all-secrets.json"

mapfile -t PROXY_SECRETS < <(kubectl get secrets -n tailscale -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | grep '^ts-' || true)

SECRETS_TO_DELETE=()
if kubectl get secret operator -n tailscale &>/dev/null; then
  SECRETS_TO_DELETE+=(operator)
fi
for secret in "${PROXY_SECRETS[@]}"; do
  SECRETS_TO_DELETE+=("$secret")
done

if [ "${#SECRETS_TO_DELETE[@]}" -gt 0 ]; then
  echo "Deleting stale Tailscale identity Secrets: ${SECRETS_TO_DELETE[*]}"
  kubectl delete secret -n tailscale "${SECRETS_TO_DELETE[@]}"
else
  echo "No Tailscale identity Secrets found to delete."
fi

if kubectl get deployment operator -n tailscale &>/dev/null; then
  echo "Restarting Tailscale operator..."
  kubectl rollout restart deployment/operator -n tailscale
  kubectl rollout status deployment/operator -n tailscale --timeout=180s
fi

mapfile -t PROXY_PODS < <(kubectl get pods -n tailscale \
  -l tailscale.com/managed=true,tailscale.com/parent-resource-type=svc \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)

if [ "${#PROXY_PODS[@]}" -gt 0 ]; then
  echo "Restarting Tailscale proxy pods: ${PROXY_PODS[*]}"
  kubectl delete pod -n tailscale "${PROXY_PODS[@]}"
  kubectl wait --for=condition=Ready pod -n tailscale \
    -l tailscale.com/managed=true,tailscale.com/parent-resource-type=svc \
    --timeout=180s
else
  echo "No Tailscale proxy pods found."
fi

cat <<EOF
Reset complete.

Next steps when Tailnet Lock is enabled:
  scripts/homelab tailscale sign
  scripts/homelab tailscale check
EOF
  )
}

command_tailscale_sign() {
  (
set -euo pipefail

SIGN_CMD=(tailscale lock sign)
if [ "${1:-}" = "--sudo" ]; then
  SIGN_CMD=(sudo tailscale lock sign)
fi

if ! tailscale lock status | grep -q 'Tailnet Lock is ENABLED'; then
  echo "Tailnet Lock is not enabled. No proxy signing required."
  exit 0
fi

mapfile -t PROXY_PODS < <(kubectl get pods -n tailscale \
  -l tailscale.com/managed=true,tailscale.com/parent-resource-type=svc \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)

if [ "${#PROXY_PODS[@]}" -eq 0 ]; then
  echo "No Tailscale proxy pods found."
  exit 0
fi

SIGNED=0
NEEDS_SUDO=0
for pod in "${PROXY_PODS[@]}"; do
  echo "Checking $pod..."
  STATUS_JSON=$(kubectl exec -n tailscale "$pod" -c tailscale -- tailscale status --json 2>/dev/null || true)
  if [ -z "$STATUS_JSON" ]; then
    echo "  Could not read tailscale status. Skipping."
    continue
  fi

  NODE_KEY=$(printf '%s' "$STATUS_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("Self", {}).get("PublicKey", ""))')
  DNS_NAME=$(printf '%s' "$STATUS_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("Self", {}).get("DNSName", ""))')
  HEALTH=$(printf '%s' "$STATUS_JSON" | python3 -c 'import json,sys; print("\n".join(json.load(sys.stdin).get("Health", [])))')

  echo "  DNS: ${DNS_NAME:-unknown}"
  if [ -z "$NODE_KEY" ]; then
    echo "  Node key missing. Skipping."
    continue
  fi

  if ! printf '%s' "$HEALTH" | grep -q 'locked out'; then
    echo "  Already signed or not locked out."
    continue
  fi

  echo "  Signing node key: $NODE_KEY"
  if "${SIGN_CMD[@]}" "$NODE_KEY"; then
    SIGNED=$((SIGNED + 1))
    echo "  Signed."
  else
    echo "  Signing failed. If access is denied, rerun: scripts/homelab tailscale sign --sudo"
    NEEDS_SUDO=1
  fi
done

if [ "$NEEDS_SUDO" -ne 0 ]; then
  exit 1
fi

echo "Signed proxy nodes: $SIGNED"
  )
}

command_tailscale_check() {
  (
# Check Tailscale proxy DNS, Serve status, and HTTPS access.

set -Eeuo pipefail

PROJECT_ROOT="$ROOT_DIR"

# shellcheck source=scripts/lib/common.sh
source "${PROJECT_ROOT}/scripts/lib/common.sh"
common::load_config "${PROJECT_ROOT}/config.env"
common::install_traps
# shellcheck source=scripts/lib/tailscale.sh
source "${PROJECT_ROOT}/scripts/lib/tailscale.sh"

usage() {
  cat <<'USAGE'
Usage:
  scripts/homelab tailscale check [host[:path] ...]

Configuration:
  TAILSCALE_ACCESS_HOSTS may contain a space-separated list of host[:path]
  entries. If arguments are provided, they override config.env.
USAGE
}

HOSTS=()
if (($# > 0)); then
  case "${1:-}" in
    -h|--help)
      usage
      exit 0
      ;;
  esac
  HOSTS=("$@")
elif [[ -n "${TAILSCALE_ACCESS_HOSTS:-}" ]]; then
  read -r -a HOSTS <<<"${TAILSCALE_ACCESS_HOSTS}"
elif [[ -n "${TAILSCALE_TAILNET_DOMAIN:-}" ]]; then
  HOSTS=(
    "openbao-openbao.${TAILSCALE_TAILNET_DOMAIN}:/ui/"
    "kube-system-headlamp.${TAILSCALE_TAILNET_DOMAIN}:/"
  )
else
  common::die "No Tailscale hosts configured. Set TAILSCALE_TAILNET_DOMAIN or TAILSCALE_ACCESS_HOSTS in config.env, or pass host[:path] arguments."
fi

FAILED=0

log::section "Tailscale Kubernetes proxy pods"
kubectl get pods -n "${TAILSCALE_NAMESPACE}" \
  -l tailscale.com/managed=true,tailscale.com/parent-resource-type=svc \
  -o wide || true

log::section "Tailscale Serve status"
mapfile -t PROXY_PODS < <(tailscale::proxy_pods)
for pod in "${PROXY_PODS[@]}"; do
  echo "--- ${pod} ---"
  kubectl exec -n "${TAILSCALE_NAMESPACE}" "${pod}" -c tailscale -- tailscale serve status 2>/dev/null || true
done

log::section "DNS and HTTPS checks"
for item in "${HOSTS[@]}"; do
  host="${item%%:*}"
  path="${item#*:}"
  if [[ "${host}" == "${path}" ]]; then
    path="/"
  fi

  echo "--- ${host} ---"
  if getent hosts "${host}"; then
    log::success "DNS OK"
  else
    log::error "DNS FAILED"
    FAILED=$((FAILED + 1))
    continue
  fi

  response_file=""
  error_file=""
  common::mktemp_var response_file
  common::mktemp_var error_file
  if curl -kI --max-time 15 "https://${host}${path}" >"${response_file}" 2>"${error_file}"; then
    sed -n '1,8p' "${response_file}"
    log::success "HTTPS OK"
  else
    log::error "HTTPS FAILED"
    sed -n '1,8p' "${error_file}" || true
    FAILED=$((FAILED + 1))
  fi
done

if [[ "${FAILED}" -gt 0 ]]; then
  common::die "Checks failed: ${FAILED}"
fi

log::success "All Tailscale access checks passed."
  )
}

command_tailscale_status() {
  # Serve configuration moved to declarative tailscale-class Ingresses
  # (audit v2 remediation, 2026-08-31). Show proxy state instead.
  kubectl get ingress -A 2>/dev/null || true
  kubectl get pods -n "${TAILSCALE_NAMESPACE:-tailscale}" \
    -l tailscale.com/managed=true -o wide || true
}

command_tailscale_restore() {
  (
set -euo pipefail

PROJECT_ROOT="$ROOT_DIR"
# shellcheck source=scripts/lib/common.sh
source "${PROJECT_ROOT}/scripts/lib/common.sh"
common::load_config "${PROJECT_ROOT}/config.env"
# shellcheck source=scripts/lib/tailscale.sh
source "${PROJECT_ROOT}/scripts/lib/tailscale.sh"

BACKUP_DIR="${1:-}"
[[ -n "${BACKUP_DIR}" ]] || common::die "Usage: $0 <validated-backup-directory>"
[[ -d "${BACKUP_DIR}" ]] || common::die "Backup directory does not exist: ${BACKUP_DIR}"

# Input-boundary validation: every required file is validated BEFORE any
# cluster mutation, so invalid or partial backups fail before recovery
# creates a namespace or applies anything.
if [[ ! -s "${BACKUP_DIR}/operator.json" && -s "${BACKUP_DIR}/all-secrets.json" ]]; then
  common::die "Backup contains only all-secrets.json (a forensic/reset snapshot), not the required operator.json. Recovery restores tailscale/operator only; proxy ts-* identities are not restored by design."
fi
tailscale::validate_oauth_file "${BACKUP_DIR}/operator-oauth.json"
tailscale::validate_identity_file "${BACKUP_DIR}/operator.json"

! k8s::deployment_exists "${TAILSCALE_NAMESPACE}" "${TAILSCALE_OPERATOR_DEPLOYMENT}" || common::die "Refusing to patch identity after the Tailscale operator has started."

tailscale::note_excluded_proxy_identities "${BACKUP_DIR}"
tailscale::ensure_namespace
tailscale::restore_operator_identity "${BACKUP_DIR}/operator.json"
if [[ -s "${BACKUP_DIR}/operator-oauth.json" ]]; then
  python3 - "${BACKUP_DIR}/operator-oauth.json" <<'PY' | kubectl apply -f -
import json, sys
d = json.load(open(sys.argv[1]))
m = d.setdefault('metadata', {})
for key in ('creationTimestamp','resourceVersion','uid','managedFields','selfLink','ownerReferences'):
    m.pop(key, None)
m['namespace'] = 'tailscale'
d.pop('status', None)
json.dump(d, sys.stdout)
PY
fi

k8s::secret_exists "${TAILSCALE_NAMESPACE}" "${TAILSCALE_OPERATOR_SECRET}" || common::die "Restored operator identity Secret is absent."
log::success "Validated Tailscale identity restored before operator startup."
  )
}

command="${1:-}"
[[ $# -gt 0 ]] && shift
case "$command" in
  install) command_tailscale_install "$@" ;;
  reset) command_tailscale_reset "$@" ;;
  sign) command_tailscale_sign "$@" ;;
  check) command_tailscale_check "$@" ;;
  status) command_tailscale_status "$@" ;;
  restore) command_tailscale_restore "$@" ;;
  *) echo "Unknown tailscale command: $command" >&2; exit 2 ;;
esac
