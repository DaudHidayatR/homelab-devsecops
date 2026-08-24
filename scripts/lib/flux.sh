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
  log::info "Reconciling Flux infrastructure before applications."
  flux reconcile source git flux-system
  flux reconcile kustomization infrastructure --with-source
  flux reconcile kustomization apps
  flux get kustomizations
  kubectl wait --for=condition=Ready nodes --all --timeout=120s
  kubectl get pods -A
  log::success "Flux reconciliation and cluster workload checks completed."
}

flux::bootstrap_or_apply() {
  local mode_var_name="$1"
  local semver_var_name="$2"

  printf -v "${mode_var_name}" '%s' "not-started"
  printf -v "${semver_var_name}" '%s' "disabled"

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

  if [[ -n "${FLUX_GIT_TAG:-}" ]]; then
    log::info "Switching Flux to semver-based deployment (range=${FLUX_GIT_TAG})."
    # Replace the branch-tracked GitRepository with an explicit semver ref in
    # one atomic operation. Recreate (not patch) so the ref object is built
    # from scratch: it carries exactly one selector (--tag-semver) and never
    # retains a stale branch/tag/commit key. The configuration selects both
    # a bootstrap branch (FLUX_GITHUB_BRANCH) and a semver range
    # (FLUX_GIT_TAG); the semver selector resolves that ambiguity by fully
    # replacing the branch selector for spec.ref — the branch stays in use
    # only for the initial bootstrap. Fail loudly if the switch does not apply.
    kubectl delete gitrepository flux-system -n flux-system --ignore-not-found
    flux create source git flux-system \
      --url="https://github.com/${GITHUB_USER}/${FLUX_GITHUB_REPOSITORY}" \
      --tag-semver="${FLUX_GIT_TAG}" \
      --interval=1m \
      --namespace=flux-system
    log::success "Flux now watches semver tags (${FLUX_GIT_TAG}) instead of branch '${FLUX_GITHUB_BRANCH}'."
    printf -v "${semver_var_name}" '%s' "enabled (${FLUX_GIT_TAG})"
    log::info "Push a semver tag to deploy: make tag v=0.0.1"
  fi
}
