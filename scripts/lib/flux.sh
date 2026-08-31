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

# Converge the flux-system source to the branch-main GitOps model (decision
# 2026-08-31). A cluster bootstrapped from a temporary bootstrap branch keeps
# fetching that branch forever: layers stay Ready on the last-good artifact
# while main advances and new manifests (e.g. platform/tailscale) never apply.
# Declaring the source here makes 'make up' idempotently converge it — the
# same declaration as the CI deploy job (.github/workflows/IaC.yml). The
# public repository is fetched unauthenticated over HTTPS; an SSH origin is
# normalized so no credentials are embedded in the cluster.
flux::converge_source() {
  local repo_root="$1" url
  local branch="${FLUX_GITHUB_BRANCH:-main}"

  url="$(git -C "${repo_root}" remote get-url origin 2>/dev/null || true)"
  if [[ -n "${url}" ]]; then
    case "${url}" in
      git@github.com:*) url="https://github.com/${url#git@github.com:}" ;;
    esac
  else
    [[ -n "${GITHUB_USER:-}" && -n "${FLUX_GITHUB_REPOSITORY:-}" ]] ||
      common::die "Cannot determine the GitOps repository URL for the flux-system source (no git origin). Set GITHUB_USER and FLUX_GITHUB_REPOSITORY in config.env."
    url="https://github.com/${GITHUB_USER}/${FLUX_GITHUB_REPOSITORY}.git"
  fi

  log::info "Converging GitRepository flux-system to branch '${branch}' (${url})."
  kubectl apply -f - <<EOF
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: flux-system
  namespace: flux-system
spec:
  interval: 1m
  url: ${url}
  ref:
    branch: ${branch}
EOF
  kubectl wait gitrepository/flux-system -n flux-system --for=condition=Ready --timeout=5m
}

# Verify the Flux source artifact matches the checked-out git HEAD before
# trusting layer readiness (audit v2 follow-up, 2026-09-01). With a stale or
# failed source fetch, every Kustomization keeps reporting Ready on the
# last-good artifact while new manifests (e.g. platform/tailscale) never
# apply — which previously surfaced only as the opaque stage-5 failure
# "HelmRelease tailscale-operator not found". Die here with an actionable
# message instead.
flux::verify_source_sync() {
  local repo_root="$1"
  local head revision

  head="$(git -C "${repo_root}" rev-parse HEAD 2>/dev/null)" ||
    common::die "Cannot resolve git HEAD in '${repo_root}': source-sync verification needs a git checkout."

  # Best-effort nudge so a transiently stale artifact refreshes before the
  # comparison; the decisive check is the revision comparison below.
  flux reconcile source git flux-system --timeout=120s >/dev/null 2>&1 || true

  revision="$(kubectl get gitrepository flux-system -n flux-system \
    -o jsonpath='{.status.artifact.revision}' 2>/dev/null || true)"
  if [[ -z "${revision}" ]]; then
    common::die "GitRepository flux-system has no synced artifact. Check 'flux get sources git' and source-controller events in flux-system, then rerun 'make up'."
  fi
  if [[ "${revision}" != *"${head}"* ]]; then
    common::die "GitRepository flux-system is stale: synced artifact '${revision}' does not match git HEAD '${head}'. Layers would verify against the last-good state while current manifests never apply. Fix the Flux source (fetch auth/network or watched ref) and rerun 'make up'."
  fi
  log::info "Flux source synced at git HEAD ${head:0:12}."
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
