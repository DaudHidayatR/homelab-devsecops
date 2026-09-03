#!/usr/bin/env bash
# Shared Kubernetes helpers for homelab scripts.

if [[ -n "${KIND_KUBERNETES_SH_LOADED:-}" ]]; then
  return 0
fi
KIND_KUBERNETES_SH_LOADED=1

# shellcheck source=scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

k8s::namespace_exists() {
  kubectl get namespace "$1" >/dev/null 2>&1
}

k8s::ensure_namespace() {
  local namespace="$1"
  kubectl create namespace "${namespace}" --dry-run=client -o yaml | kubectl apply -f -
}

k8s::secret_exists() {
  local namespace="$1"
  local secret_name="$2"
  kubectl get secret "${secret_name}" -n "${namespace}" >/dev/null 2>&1
}

k8s::deployment_exists() {
  local namespace="$1"
  local deployment_name="$2"
  kubectl get deployment "${deployment_name}" -n "${namespace}" >/dev/null 2>&1
}

k8s::pod_exists() {
  local namespace="$1"
  local pod_name="$2"
  kubectl get pod "${pod_name}" -n "${namespace}" >/dev/null 2>&1
}

k8s::service_exists() {
  local namespace="$1"
  local service_name="$2"
  kubectl get svc "${service_name}" -n "${namespace}" >/dev/null 2>&1
}

k8s::wait_pod_ready() {
  local namespace="$1"
  local pod_name="$2"
  local timeout="${3:-300s}"
  kubectl wait --for=condition=Ready "pod/${pod_name}" -n "${namespace}" --timeout="${timeout}"
}

k8s::wait_deployment_ready() {
  local namespace="$1"
  local deployment_name="$2"
  local timeout="${3:-120s}"
  kubectl rollout status "deployment/${deployment_name}" -n "${namespace}" --timeout="${timeout}"
}

k8s::apply_kustomize() {
  local path="$1"
  kubectl apply -k "${path}"
}

k8s::annotate_service() {
  local namespace="$1"
  local service_name="$2"
  shift 2
  kubectl annotate svc "${service_name}" -n "${namespace}" "$@" --overwrite
}
