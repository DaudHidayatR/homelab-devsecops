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

: "${FLUX_GITHUB_REPOSITORY:=homelab-devsecops}"
: "${FLUX_GITHUB_BRANCH:=main}"
: "${FLUX_CLUSTER_PATH:=./clusters/kind}"

flux::apply_fallback() {
  local reason="$1"
  log::warn "Falling back to direct kubectl apply (${reason})."
  k8s::apply_kustomize "${COMMON_REPO_ROOT}/infrastructure"
  k8s::apply_kustomize "${COMMON_REPO_ROOT}/apps"
}

flux::bootstrap_or_apply() {
  local mode_var_name="$1"
  local semver_var_name="$2"

  printf -v "${mode_var_name}" '%s' "not-started"
  printf -v "${semver_var_name}" '%s' "disabled"

  if ! command -v flux >/dev/null 2>&1; then
    log::warn "Flux CLI not found. Install from https://fluxcd.io/flux/installation/"
    printf -v "${mode_var_name}" '%s' "direct kubectl apply fallback (Flux CLI unavailable)"
    flux::apply_fallback "Flux CLI unavailable"
    return 0
  fi

  log::info "Flux CLI found. Running pre-flight checks."
  if ! flux check --pre >/dev/null 2>&1; then
    printf -v "${mode_var_name}" '%s' "direct kubectl apply fallback (Flux preflight failed)"
    flux::apply_fallback "Flux preflight failed"
    return 0
  fi

  if [[ -z "${GITHUB_TOKEN:-}" || -z "${GITHUB_USER:-}" ]]; then
    log::warn "GITHUB_TOKEN or GITHUB_USER not set. Set them in config.env or environment to enable GitOps."
    printf -v "${mode_var_name}" '%s' "direct kubectl apply fallback (missing GitHub credentials)"
    flux::apply_fallback "missing GitHub credentials"
    return 0
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
    kubectl patch gitrepository flux-system -n flux-system \
      --type merge -p "{\"spec\":{\"ref\":{\"semver\":\"${FLUX_GIT_TAG}\"},\"interval\":\"1m\"}}"
    log::success "Flux now watches semver tags (${FLUX_GIT_TAG}) instead of branch '${FLUX_GITHUB_BRANCH}'."
    printf -v "${semver_var_name}" '%s' "enabled (${FLUX_GIT_TAG})"
    log::info "Push a semver tag to deploy: make tag v=0.0.1"
  fi
}
