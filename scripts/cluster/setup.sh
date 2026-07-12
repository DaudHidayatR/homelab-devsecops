#!/usr/bin/env bash
# Deploy the full kind cluster and supporting DevSecOps components.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck source=scripts/lib/common.sh
source "${PROJECT_ROOT}/scripts/lib/common.sh"
COMMON_REQUIRE_CONFIG=true
ENV_GITHUB_USER="${GITHUB_USER-}"
ENV_GITHUB_TOKEN="${GITHUB_TOKEN-}"
common::load_config "${PROJECT_ROOT}/config.env"
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
FLUX_SEMVER_MODE="disabled"
TAILSCALE_MODE="skipped"
OPENBAO_POST_SETUP_REQUIRED="yes"


openbao::annotate_tailscale_service() {
  log::section "4.5. Configuring Tailscale annotations on OpenBao"
  # The OpenBao Helm chart creates multiple services, but only the main
  # openbao Service should be exposed to avoid duplicate Tailscale proxies.
  if k8s::service_exists "${OPENBAO_NS}" "openbao"; then
    k8s::annotate_service "${OPENBAO_NS}" "openbao" \
      tailscale.com/expose=true \
      tailscale.com/serve=true
    log::success "OpenBao main Service annotated for Tailscale."
  else
    log::warn "openbao Service not found; skipping annotation."
  fi
}

tailscale::install_if_configured() {
  log::section "5. Installing Tailscale Operator (optional)"
  if [[ -n "${TAILSCALE_CLIENT_ID:-}" && -n "${TAILSCALE_CLIENT_SECRET:-}" ]]; then
    TAILSCALE_MODE="enabled"
    tailscale::install_full ""
  else
    TAILSCALE_MODE="skipped (missing OAuth credentials)"
    log::warn "TAILSCALE_CLIENT_ID or TAILSCALE_CLIENT_SECRET not set. Skipping Tailscale operator."
  fi
}

setup::print_preflight_notes() {
  log::section "2. Istio deployment"
  log::info "Istio will be deployed via Flux HelmRelease (infrastructure/istio/)."

  log::section "3. RabbitMQ credentials"
  cat <<'MSG'
RabbitMQ credentials are sourced from OpenBao via External Secrets Operator.
The External Secrets Operator syncs secret/data/messaging/rabbitmq from OpenBao
into the Kubernetes Secret messaging/rabbitmq-credentials.

If this is a fresh cluster, after 'make up' completes, run:
  bash scripts/openbao/bootstrap.sh
  bash scripts/openbao/store-rabbitmq.sh
  kubectl apply -k infrastructure/external-secrets/stores
MSG
}

setup::print_summary() {
  log::section "Setup Summary"
  cat <<MSG
Deployment mode: ${DEPLOYMENT_MODE}
Flux semver mode: ${FLUX_SEMVER_MODE}
Tailscale mode: ${TAILSCALE_MODE}
OpenBao post-setup required: ${OPENBAO_POST_SETUP_REQUIRED}

If this is a fresh OpenBao install, run these after the OpenBao pod is ready:
  kubectl wait --for=condition=Ready pod/${OPENBAO_POD} -n ${OPENBAO_NS} --timeout=300s
  bash scripts/openbao/bootstrap.sh
  bash scripts/openbao/store-rabbitmq.sh
  kubectl apply -k infrastructure/external-secrets/stores
MSG
}

main() {
  common::require_commands kind kubectl python3

  log::section "1. Creating kind cluster (rootless)"
  cluster::ensure_kind "${PROJECT_ROOT}/kind/cluster.yaml"

  setup::print_preflight_notes


  log::section "4. Bootstrapping Flux CD"
  flux::bootstrap_or_apply DEPLOYMENT_MODE FLUX_SEMVER_MODE

  openbao::annotate_tailscale_service
  tailscale::install_if_configured
  setup::print_summary

  # SRP: access instructions live in their own script; setup ends at infrastructure readiness.
  "${PROJECT_ROOT}/scripts/access/show-info.sh"
}

main "$@"
