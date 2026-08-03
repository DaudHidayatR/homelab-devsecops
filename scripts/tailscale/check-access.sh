#!/usr/bin/env bash
# Check Tailscale proxy DNS, Serve status, and HTTPS access.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck source=scripts/lib/common.sh
source "${PROJECT_ROOT}/scripts/lib/common.sh"
common::load_config "${PROJECT_ROOT}/config.env"
common::install_traps
# shellcheck source=scripts/lib/tailscale.sh
source "${PROJECT_ROOT}/scripts/lib/tailscale.sh"

usage() {
  cat <<'USAGE'
Usage:
  ./scripts/tailscale/check-access.sh [host[:path] ...]

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
