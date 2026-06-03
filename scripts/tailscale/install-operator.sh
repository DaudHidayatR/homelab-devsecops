#!/usr/bin/env bash
# Tailscale Kubernetes Operator Installer.
# This standalone entrypoint uses the same shared lifecycle as setup.sh.

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
  ./scripts/tailscale/install-operator.sh [options]

Options:
  -h, --help          Show this help
  --operator-only     Install only the operator, without Serve configuration

Configuration:
  TAILSCALE_CLIENT_ID and TAILSCALE_CLIENT_SECRET are read from config.env or
  the current environment when the operator-oauth Secret does not already exist.
USAGE
}

OPERATOR_ONLY="false"

while (($# > 0)); do
  case "$1" in
    --operator-only)
      OPERATOR_ONLY="true"
      ;;
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

  log::section "Installing Tailscale Kubernetes Operator"
  tailscale::ensure_namespace
  tailscale::ensure_oauth_secret

  local identity_backup
  common::mktemp_var identity_backup
  tailscale::backup_operator_identity "${identity_backup}"
  tailscale::install_operator
  tailscale::restore_operator_identity "${identity_backup}"

  if [[ "${OPERATOR_ONLY}" != "true" ]]; then
    log::info "Waiting for Tailscale proxy pods to be ready."
    tailscale::wait_proxy_pods 30 5
    log::info "Configuring Tailscale Serve on proxy pods."
    tailscale::configure_serve
    log::info "Deploying Tailscale Serve watcher."
    tailscale::deploy_serve_watcher
  fi

  log::success "Tailscale operator installation flow complete."
  cat <<'MSG'
Services annotated with 'tailscale.com/expose: "true"' will be accessible from
your tailnet at https://<service>-<namespace>.<tailnet>.ts.net.

For public internet access, change the annotation to:
  tailscale.com/funnel: "true"
MSG
}

main "$@"
