#!/usr/bin/env bash
set -Eeuo pipefail

kind() {
  case "$1 $2" in
    "get clusters") ;;
    "create cluster")
      [[ "$5" == "--config" ]]
      [[ -f "$6" ]]
      KIND_CONFIG="$6"
      ;;
  esac
}

main() {
  local root output status
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

  set +e
  output=$("${root}/scripts/homelab" unknown command 2>&1)
  status=$?
  set -e
  [[ "$status" -eq 2 ]]
  [[ "$output" == *"Usage: scripts/homelab"* ]]

  set +e
  output=$("${root}/scripts/homelab" repository purge-secret 2>&1)
  status=$?
  set -e
  [[ "$status" -eq 2 ]]
  [[ "$output" == *"Usage: scripts/homelab"* ]]

  # shellcheck source=scripts/lib/cluster.sh
  source "${root}/scripts/lib/cluster.sh"
  trap common::cleanup EXIT
  local source_config KIND_CONFIG
  common::mktemp_var source_config /tmp/kind-source.XXXXXX.yaml
  printf 'kind: Cluster\n' >"${source_config}"
  cluster::ensure_kind "${source_config}"
  [[ "${KIND_CONFIG}" != "${source_config}" ]]
  cmp -s "${source_config}" "${KIND_CONFIG}"

  # SCAN_STATUS regression: the aggregate security-scan path must always
  # have SCAN_STATUS initialized under set -u (clean aggregation exits 0).
  # Scanner invocations are stripped so no container runtime is needed.
  local sec_src sec_shim agg_out agg_rc
  sec_src="${root}/scripts/commands/security.sh"
  sec_shim="$(mktemp "${root}/scripts/commands/.shim.XXXXXX")"
  sed -e '/^source "/d' -e '/^    scan_/d' -e '/^    validate_reports /d' \
    "${sec_src}" >"${sec_shim}"
  agg_out="$(cd / && bash "${sec_shim}" scan 2>&1)"
  agg_rc=$?
  rm -f "${sec_shim}"
  [[ "${agg_rc}" -eq 0 ]]
  [[ "${agg_out}" != *"unbound variable"* ]]
  # Scanner root resolution regression: common.sh must resolve the repository
  # root (not its parent) regardless of caller CWD and source its config.env.
  # A stub podman on PATH satisfies common.sh's runtime detection without a
  # real container runtime (the stub is never executed here).
  local scan_root stub_bin out
  scan_root="$(mktemp -d /tmp/scanner-root.XXXXXX)"
  mkdir "${scan_root}/repo"
  cp -R "${root}/scripts" "${scan_root}/repo/scripts"
  cat >"${scan_root}/repo/config.env" <<CFG
SCANNER_ROOT_TEST_MARKER=1
TRIVY_IMAGE=test
GRYPE_IMAGE=test
GITLEAKS_IMAGE=test
SEMGREP_IMAGE=test
SYFT_IMAGE=test
CHECKOV_IMAGE=test
SEVERITY=HIGH,CRITICAL
CFG
  stub_bin="$(mktemp -d /tmp/stub-bin.XXXXXX)"
  printf '#!/usr/bin/env bash
exit 0
' >"${stub_bin}/podman"
  chmod +x "${stub_bin}/podman"
  out="$(
    cd /
    export PATH="${stub_bin}:${PATH}"
    trap 'printf "%s|%s" "${PROJECT_ROOT-}" "${SCANNER_ROOT_TEST_MARKER-}"' EXIT
    source "${scan_root}/repo/scripts/lib/scanners/common.sh"
  )"
  rm -f "${stub_bin}/podman"; rmdir "${stub_bin}"
  [[ "${out%%|*}" == "${scan_root}/repo" ]]
  [[ "${out##*|}" == "1" ]]
  chmod -R u+w "${scan_root}"; rm -rf "${scan_root}"
  python3 - "${root}/scripts/commands/cluster.sh" <<'PY'
import re
import sys

source = open(sys.argv[1]).read()
wait = re.search(r'kubectl wait --for=condition=Ready \\\n((?:\s+kustomization/[^\n]+\\\n)+)\s+-n flux-system --timeout=300s', source)
assert wait
assert re.findall(r'kustomization/([\w-]+)', wait.group(1)) == [
    'bootstrap', 'cluster-resources', 'platform', 'openbao-config',
    'cluster-policies', 'operations', 'apps',
]
assert source.index(wait.group(0)) < source.index('setup::print_summary', source.index('main()'))
PY

  # P1: kind cluster config must not bind broadly and must carry loopback SANs
  # so the generated kubeconfig works without manual edits or TLS errors.
  local kind_config
  kind_config="${root}/kubernetes/clusters/homelab/bootstrap/controllers/kind-cluster.yaml"
  if grep -q 'advertiseAddress: *0\\.0\\.0\\.0\\|bindAddress: *0\\.0\\.0\\.0\\|advertiseAddress: *\\[::\\]\\|bindAddress: *\\[::\\]' "${kind_config}"; then
    echo "ERROR: kind config binds the API server broadly" >&2
    return 1
  fi
  grep -q '127.0.0.1' "${kind_config}" || { echo "ERROR: kind config lacks loopback SAN" >&2; return 1; }
  grep -q 'localhost' "${kind_config}" || { echo "ERROR: kind config lacks localhost SAN" >&2; return 1; }
  # Placeholder tokens must be renderable by cluster::render_config
  grep -q 'TAILSCALE_VPS_IP_PLACEHOLDER' "${kind_config}"

  # P1: destructive kind lifecycle operations must be bound to CLUSTER_NAME
  if grep -n 'kind delete cluster' "${root}/scripts/commands/cluster.sh" | grep -v -- '--name "$CLUSTER_NAME"' >/dev/null; then
    echo "ERROR: kind delete not bound to CLUSTER_NAME" >&2
    return 1
  fi

  # P1: the Flux semver switch must be atomic (recreate with flux create,
  # not a bare kubectl patch that can leave a half-applied ref)
  python3 - "${root}/scripts/lib/flux.sh" <<'PY'
import sys

source = open(sys.argv[1]).read()
if 'FLUX_GIT_TAG' in source:
    assert 'kubectl patch gitrepository' not in source, \
        'Flux semver switch must not use a bare kubectl patch'
    assert 'flux create source git flux-system' in source, \
        'Flux semver switch must recreate the source atomically'
    assert '--tag-semver=' in source, \
        'Flux semver switch must set tag-semver'
PY
}

main "$@"
