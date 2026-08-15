#!/usr/bin/env bash
# Shared kind cluster helpers for infra/kind scripts.

if [[ -n "${KIND_CLUSTER_SH_LOADED:-}" ]]; then
  return 0
fi
KIND_CLUSTER_SH_LOADED=1

# shellcheck source=scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

: "${CLUSTER_NAME:=kind-devsecops}"

cluster::validate_name() {
  [[ "${CLUSTER_NAME}" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ && ${#CLUSTER_NAME} -le 63 ]] ||
    common::die "CLUSTER_NAME must be a non-empty Kind-compatible DNS label (lowercase alphanumeric or '-', maximum 63 characters): '${CLUSTER_NAME}'"
}

cluster::context() {
  printf 'kind-%s\n' "${CLUSTER_NAME}"
}

cluster::exists() {
  cluster::validate_name
  kind get clusters | awk -v name="${CLUSTER_NAME}" '$0 == name {found=1} END {exit !found}'
}

cluster::render_config() {
  local __var_name="$1"
  local source_config="$2"
  local rendered_path
  common::mktemp_var rendered_path /tmp/kind-cluster.XXXXXX.yaml
  cp "${source_config}" "${rendered_path}"

  if [[ -n "${TAILSCALE_VPS_IP:-}" ]]; then
    sed -i "s/TAILSCALE_VPS_IP_PLACEHOLDER/${TAILSCALE_VPS_IP}/g" "${rendered_path}"
  else
    sed -i '/TAILSCALE_VPS_IP_PLACEHOLDER/d' "${rendered_path}"
  fi

  if [[ -n "${TAILSCALE_VPS_HOSTNAME:-}" ]]; then
    sed -i "s/TAILSCALE_VPS_HOSTNAME_PLACEHOLDER/${TAILSCALE_VPS_HOSTNAME}/g" "${rendered_path}"
  else
    sed -i '/TAILSCALE_VPS_HOSTNAME_PLACEHOLDER/d' "${rendered_path}"
  fi

  printf -v "${__var_name}" '%s' "${rendered_path}"
}

cluster::ensure_kind() {
  local source_config="$1"
  cluster::validate_name
  local rendered_config

  if cluster::exists; then
    log::info "Kind cluster '${CLUSTER_NAME}' already exists; skipping creation."
    kubectl config use-context "$(cluster::context)" >/dev/null 2>&1 || true
    return 0
  fi

  cluster::render_config rendered_config "${source_config}"
  kind create cluster --name "${CLUSTER_NAME}" --config "${rendered_config}"
}
