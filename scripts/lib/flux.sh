#!/usr/bin/env bash
# Shared Flux helpers for infra/kind scripts.

if [[ -n "${KIND_FLUX_SH_LOADED:-}" ]]; then
  return 0
fi
KIND_FLUX_SH_LOADED=1

# shellcheck source=scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
# shellcheck source=scripts/lib/kubernetes.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/kubernetes.sh"

: "${FLUX_GITHUB_BRANCH:=main}"
: "${FLUX_CLUSTER_PATH:=./kubernetes/clusters/homelab}"
: "${FLUX_BOOTSTRAP_MODE:=auto}"

flux::reconcile() {
  log::info "Reconciling Flux layers before applications."
  flux reconcile source git flux-system
  local layer
  for layer in bootstrap cluster-resources platform openbao-config cluster-policies operations apps; do
    flux reconcile kustomization "${layer}"
  done
  flux get kustomizations
  kubectl wait --for=condition=Ready nodes --all --timeout=120s
  kubectl get pods -A
  log::success "Flux reconciliation and cluster workload checks completed."
}

# Branch-main GitOps (decision 2026-08-31): Flux watches the repository's
# main branch. There is no runtime ref switching, no tag selector, and no
# 'make tag' flow; every push to main is reconciled by the source controller.
flux::bootstrap_or_apply() {
  local mode_var_name="$1"

  printf -v "${mode_var_name}" '%s' "not-started"

  if ! command -v flux >/dev/null 2>&1; then
    common::die "Flux CLI is required. Install it from https://fluxcd.io/flux/installation/; manifests will not be applied directly."
  fi

  log::info "Flux CLI found. Running pre-flight checks."
  if ! flux check --pre; then
    common::die "Flux preflight failed. Resolve the reported prerequisites; manifests will not be applied directly."
  fi

  case "${FLUX_BOOTSTRAP_MODE}" in
    auto|github) ;;
    *) common::die "FLUX_BOOTSTRAP_MODE must be 'auto' or 'github': '${FLUX_BOOTSTRAP_MODE}'" ;;
  esac

  if kubectl get deployment source-controller -n flux-system >/dev/null 2>&1; then
    log::info "Flux is already installed; skipping GitHub bootstrap."
    flux::reconcile
    printf -v "${mode_var_name}" '%s' "Flux GitOps"
  elif [[ -f "${PROJECT_ROOT}/${FLUX_CLUSTER_PATH#./}/flux-system/kustomization.yaml" ]]; then
    log::info "Installing Flux from committed bootstrap manifests."
    kubectl apply -k "${PROJECT_ROOT}/${FLUX_CLUSTER_PATH#./}/flux-system"
    kubectl rollout status deployment/source-controller -n flux-system --timeout=300s
    flux::reconcile
    printf -v "${mode_var_name}" '%s' "Flux GitOps"
  elif [[ "${FLUX_BOOTSTRAP_MODE}" == github ]]; then
    [[ -n "${FLUX_GITHUB_REPOSITORY:-}" ]] || common::die "FLUX_GITHUB_REPOSITORY is required for Flux bootstrap."
    if [[ -z "${GITHUB_TOKEN:-}" || -z "${GITHUB_USER:-}" ]]; then
      common::die "GITHUB_TOKEN and GITHUB_USER are required when FLUX_BOOTSTRAP_MODE=github."
    fi

    log::info "Bootstrapping Flux from GitHub repository ${GITHUB_USER}/${FLUX_GITHUB_REPOSITORY}."
    flux bootstrap github \
      --owner="${GITHUB_USER}" \
      --repository="${FLUX_GITHUB_REPOSITORY}" \
      --branch="${FLUX_GITHUB_BRANCH}" \
      --path="${FLUX_CLUSTER_PATH}" \
      --personal
    log::success "Flux bootstrapped. Cluster state is now managed by GitOps."
    flux::reconcile
    printf -v "${mode_var_name}" '%s' "Flux GitOps"
  else
    common::die "Flux bootstrap manifests are not committed at '${FLUX_CLUSTER_PATH}/flux-system'. Protected branch flow: run 'flux bootstrap github --owner=${GITHUB_USER:-OWNER} --repository=${FLUX_GITHUB_REPOSITORY:-REPOSITORY} --branch=flux-bootstrap --path=${FLUX_CLUSTER_PATH} --personal', then merge that branch through a signed pull request and rerun make up. Set FLUX_BOOTSTRAP_MODE=github only when direct pushes are allowed."
  fi
}
