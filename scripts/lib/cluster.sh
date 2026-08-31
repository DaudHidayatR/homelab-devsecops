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

cluster::find_container_provider() {
  local __var_name="$1" container="$2"
  local candidate id found="" found_id="" queried=false
  local runtimes=(docker podman nerdctl)

  if [[ -n "${KIND_EXPERIMENTAL_PROVIDER:-}" ]]; then
    case "${KIND_EXPERIMENTAL_PROVIDER}" in
      docker|podman|nerdctl) runtimes=("${KIND_EXPERIMENTAL_PROVIDER}") ;;
      *) common::die "Unsupported KIND_EXPERIMENTAL_PROVIDER: '${KIND_EXPERIMENTAL_PROVIDER}'" ;;
    esac
  fi

  for candidate in "${runtimes[@]}"; do
    command -v "${candidate}" >/dev/null 2>&1 || continue
    if id="$("${candidate}" ps -a --no-trunc --filter "name=^${container}$" --format '{{.ID}}' 2>/dev/null)"; then
      queried=true
      [[ -n "${id}" ]] || continue
      if [[ -n "${found_id}" && "${id}" != "${found_id}" ]]; then
        common::die "Kind control-plane container '${container}' resolves to different runtime objects (${found}, ${candidate}); set KIND_EXPERIMENTAL_PROVIDER explicitly."
      fi
      [[ -n "${found}" ]] || found="${candidate}"
      found_id="${id}"
    fi
  done

  [[ "${queried}" == true ]] || common::die "No supported Kind container runtime could be queried."
  printf -v "${__var_name}" '%s' "${found}"
}

cluster::exists() {
  cluster::validate_name
  local context clusters
  context="$(cluster::context)"

  if clusters="$(kind get clusters 2>/dev/null)"; then
    if awk -v name="${CLUSTER_NAME}" '$0 == name {found=1} END {exit !found}' <<<"${clusters}"; then
      return 0
    fi
    if kubectl config get-contexts "${context}" --no-headers >/dev/null 2>&1; then
      common::die "Kind cluster '${CLUSTER_NAME}' is absent, but context '${context}' still exists. Remove or repair the stale context before creating a cluster."
    fi
    return 1
  fi

  local control_plane="${CLUSTER_NAME}-control-plane" runtime=""
  local context_exists=false container_exists=false
  cluster::find_container_provider runtime "${control_plane}"
  kubectl config get-contexts "${context}" --no-headers >/dev/null 2>&1 && context_exists=true
  [[ -z "${runtime}" ]] || container_exists=true

  if [[ "${context_exists}" == false && "${container_exists}" == false ]]; then
    return 1
  fi
  [[ "${context_exists}" == true ]] ||
    common::die "Kind control-plane container '${control_plane}' exists but context '${context}' is absent; refusing to create a duplicate cluster."
  [[ "${container_exists}" == true ]] ||
    common::die "Context '${context}' exists but Kind control-plane container '${control_plane}' is absent; remove or repair the stale context."
  kubectl --context "${context}" get --raw=/readyz >/dev/null 2>&1 ||
    common::die "Kind enumeration failed and context '${context}' is unreachable; refusing to reuse or replace the cluster."
  [[ "$(kubectl --context "${context}" get node "${control_plane}" -o name 2>/dev/null)" == "node/${control_plane}" ]] ||
    common::die "Context '${context}' does not contain expected node '${control_plane}'; refusing to reuse it."
  return 0
}

cluster::render_config() {
  local __var_name="$1"
  local source_config="$2"
  local rendered_config_path
  common::mktemp_var rendered_config_path /tmp/kind-cluster.XXXXXX.yaml
  cp "${source_config}" "${rendered_config_path}"

  if [[ -n "${TAILSCALE_VPS_IP:-}" ]]; then
    python3 -c 'import ipaddress, sys; sys.exit(ipaddress.ip_address(sys.argv[1]) not in ipaddress.ip_network("100.64.0.0/10"))' "${TAILSCALE_VPS_IP}" ||
      common::die "TAILSCALE_VPS_IP must be an IPv4 address in Tailscale CGNAT range 100.64.0.0/10."
    sed -i "s/KIND_API_SERVER_ADDRESS_PLACEHOLDER/${TAILSCALE_VPS_IP}/g; s/TAILSCALE_VPS_IP_PLACEHOLDER/${TAILSCALE_VPS_IP}/g" "${rendered_config_path}"
  else
    sed -i "s/KIND_API_SERVER_ADDRESS_PLACEHOLDER/127.0.0.1/g; /TAILSCALE_VPS_IP_PLACEHOLDER/d" "${rendered_config_path}"
  fi

  if [[ -n "${TAILSCALE_VPS_HOSTNAME:-}" ]]; then
    sed -i "s/TAILSCALE_VPS_HOSTNAME_PLACEHOLDER/${TAILSCALE_VPS_HOSTNAME}/g" "${rendered_config_path}"
  else
    sed -i '/TAILSCALE_VPS_HOSTNAME_PLACEHOLDER/d' "${rendered_config_path}"
  fi

  printf -v "${__var_name}" '%s' "${rendered_config_path}"
}

cluster::repair_kubeconfig_server() {
  local context kubeconfig_cluster server
  context="$(cluster::context)"
  kubeconfig_cluster="$(kubectl config view -o "jsonpath={.contexts[?(@.name=='${context}')].context.cluster}")"
  server="$(kubectl config view -o "jsonpath={.clusters[?(@.name=='${kubeconfig_cluster}')].cluster.server}")"
  if [[ "${server}" == https://0.0.0.0:* ]]; then
    kubectl config set-cluster "${kubeconfig_cluster}" --server="${server/0.0.0.0/127.0.0.1}" >/dev/null
    log::info "Repaired kubeconfig API address ${server} to use 127.0.0.1."
  fi
}

cluster::ensure_kind() {
  local source_config="$1"
  cluster::validate_name
  local rendered_config

  if cluster::exists; then
    log::info "Kind cluster '${CLUSTER_NAME}' already exists; skipping creation."
    kubectl config use-context "$(cluster::context)" >/dev/null 2>&1 || true
    cluster::repair_kubeconfig_server
    return 0
  fi

  cluster::render_config rendered_config "${source_config}"
  kind create cluster --name "${CLUSTER_NAME}" --config "${rendered_config}"
  cluster::repair_kubeconfig_server
}
