#!/usr/bin/env bash
# Shared kind cluster helpers for infra/kind scripts.

if [[ -n "${KIND_CLUSTER_SH_LOADED:-}" ]]; then
  return 0
fi
KIND_CLUSTER_SH_LOADED=1

# shellcheck source=scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

: "${CLUSTER_NAME:=kind-devsecops}"
: "${CLUSTER_CONTEXT:=kind-${CLUSTER_NAME}}"

cluster::exists() {
  kind get clusters | awk -v name="${CLUSTER_NAME}" '$0 == name {found=1} END {exit !found}'
}

cluster::render_config() {
  local __var_name="$1"
  local source_config="$2"
  local rendered_config
  common::mktemp_var rendered_config /tmp/kind-cluster.XXXXXX.yaml
  cp "${source_config}" "${rendered_config}"

  if [[ -n "${TAILSCALE_VPS_IP:-}" ]]; then
    sed -i "s/TAILSCALE_VPS_IP_PLACEHOLDER/${TAILSCALE_VPS_IP}/g" "${rendered_config}"
  else
    sed -i '/TAILSCALE_VPS_IP_PLACEHOLDER/d' "${rendered_config}"
  fi

  if [[ -n "${TAILSCALE_VPS_HOSTNAME:-}" ]]; then
    sed -i "s/TAILSCALE_VPS_HOSTNAME_PLACEHOLDER/${TAILSCALE_VPS_HOSTNAME}/g" "${rendered_config}"
  else
    sed -i '/TAILSCALE_VPS_HOSTNAME_PLACEHOLDER/d' "${rendered_config}"
  fi

  printf -v "${__var_name}" '%s' "${rendered_config}"
}

cluster::ensure_kind() {
  local source_config="$1"
  local rendered_config

  if cluster::exists; then
    log::info "Kind cluster '${CLUSTER_NAME}' already exists; skipping creation."
    kubectl config use-context "${CLUSTER_CONTEXT}" >/dev/null 2>&1 || true
    return 0
  fi

  cluster::render_config rendered_config "${source_config}"
  kind create cluster --config "${rendered_config}"
}
