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

  [[ -n "${FLUX_GITHUB_REPOSITORY:-}" ]] || common::die "FLUX_GITHUB_REPOSITORY is required for Flux bootstrap."
  if [[ -z "${GITHUB_TOKEN:-}" || -z "${GITHUB_USER:-}" ]]; then
    common::die "GITHUB_TOKEN and GITHUB_USER must be provided via the environment for Flux bootstrap; manifests will not be applied directly."
  fi

  log::info "Bootstrapping Flux from GitHub repository ${GITHUB_USER}/${FLUX_GITHUB_REPOSITORY}."
  flux bootstrap github \
    --owner="${GITHUB_USER}" \
    --repository="${FLUX_GITHUB_REPOSITORY}" \
    --branch="${FLUX_GITHUB_BRANCH}" \
    --path="${FLUX_CLUSTER_PATH}" \
    --personal
  log::success "Flux bootstrapped. Cluster state is now managed by GitOps."
  printf -v "${mode_var_name}" '%s' "Flux GitOps"

  if [[ -n "${FLUX_GIT_TAG:-}" ]]; then
    log::info "Switching Flux to semver-based deployment (range=${FLUX_GIT_TAG})."
    # Replace the branch-tracked GitRepository with an explicit semver ref in
    # one atomic operation. Recreate (not patch) so the ref and interval are
    # set together; fail loudly if the switch does not apply.
    kubectl delete gitrepository flux-system -n flux-system --ignore-not-found
    flux create source git flux-system \
      --url="https://github.com/${GITHUB_USER}/${FLUX_GITHUB_REPOSITORY}" \
      --branch="${FLUX_GITHUB_BRANCH}" \
      --tag-semver="${FLUX_GIT_TAG}" \
      --interval=1m \
      --namespace=flux-system
    log::success "Flux now watches semver tags (${FLUX_GIT_TAG}) instead of branch '${FLUX_GITHUB_BRANCH}'."
    printf -v "${semver_var_name}" '%s' "enabled (${FLUX_GIT_TAG})"
    log::info "Push a semver tag to deploy: make tag v=0.0.1"
  fi
}
