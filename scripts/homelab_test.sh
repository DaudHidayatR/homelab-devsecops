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
  # shellcheck disable=SC2016 # literal pattern; $CLUSTER_NAME must stay unexpanded
  if grep -n 'kind delete cluster' "${root}/scripts/commands/cluster.sh" | grep -v -- '--name "$CLUSTER_NAME"' >/dev/null; then
    echo "ERROR: kind delete not bound to CLUSTER_NAME" >&2
    return 1
  fi

  # P1: the Flux semver switch must be atomic (recreate with flux create,
  # not a bare kubectl patch that can leave a half-applied ref)
  python3 - "${root}/scripts/lib/flux.sh" "${root}/.github/workflows/IaC.yml" <<'PY'
import sys

source = open(sys.argv[1]).read()
if 'FLUX_GIT_TAG' in source:
    assert 'kubectl patch gitrepository' not in source, \
        'Flux semver switch must not use a bare kubectl patch'
    assert 'flux create source git flux-system' in source, \
        'Flux semver switch must recreate the source atomically'
    assert '--tag-semver=' in source, \
        'Flux semver switch must set tag-semver'

# CI deploy job: the flux-system GitRepository must be switched to semver
# by recreating it (flux create source git --tag-semver), never by a merge
# patch that could leave a stale branch/tag/commit key next to semver.
ci = open(sys.argv[2]).read()
if 'kubectl patch gitrepository flux-system' in ci:
    raise AssertionError('CI must not merge-patch GitRepository spec.ref')
if 'flux create source git flux-system' in ci:
    assert '--tag-semver=' in ci, \
        'CI flux source recreation must set tag-semver'
    assert 'kubectl delete gitrepository flux-system' in ci, \
        'CI flux source recreation must replace the object atomically'
PY

  # P1: Tailscale helpers must define every symbol the command layer calls,
  # and the install ordering must be backup -> install -> restore (restore
  # guarded against running after the Deployment exists).
  python3 - "${root}/scripts/commands/tailscale.sh" "${root}/scripts/lib/tailscale.sh" <<'PY'
import re
import sys

cmd, lib = open(sys.argv[1]).read(), open(sys.argv[2]).read()

# Every tailscale:: symbol called from the command layer must be defined.
calls = set(re.findall(r'tailscale::([a-z_0-9]+)', cmd))
defs = set(re.findall(r'tailscale::([a-z_0-9]+)\(\)', lib))
missing = calls - defs
assert not missing, f'undefined Tailscale symbols: {sorted(missing)}'

# Ordering: backup must appear before install_operator, and restore after it.
cmd_main = cmd[cmd.index('main()'):]
assert cmd_main.index('tailscale::backup_operator_identity') < \
       cmd_main.index('tailscale::install_operator') < \
       cmd_main.index('tailscale::restore_operator_identity'), \
    'Tailscale install ordering must be backup -> install -> restore'

# Restore must be guarded against running after the Deployment exists.
assert 'Refusing to restore identity after the Tailscale operator has started' in lib, \
    'restore_operator_identity must refuse to run after the Deployment exists'
PY

  # P1: lifecycle backup must be bound to the Tailscale backup root and
  # destructive operations to CLUSTER_NAME.
  # shellcheck disable=SC2016 # literal patterns; variables must stay unexpanded
  grep -q 'kind delete cluster --name "$CLUSTER_NAME"' "${root}/scripts/commands/cluster.sh" || {
    echo "ERROR: kind delete not bound to CLUSTER_NAME" >&2; return 1; }
  grep -q 'TAILSCALE_BACKUP_DIR' "${root}/scripts/commands/cluster.sh" || {
    echo "ERROR: cluster down must use TAILSCALE_BACKUP_DIR" >&2; return 1; }

  # OpenBao Raft persistence: the values file must keep the Raft storage
  # path in lock-step with the PVC mount (/openbao/data) so Raft state lands
  # on the PVC and survives pod replacement. Mirrors the CI gate.
  python3 "${root}/scripts/check_openbao_raft_path.py" "${root}"

  # P1: the OpenBao backup-and-recovery procedure in the README must stay
  # explicit and actionable: prerequisites, a save command, an off-PVC
  # storage location, a restore command, and validation. The procedure must
  # use the final /openbao/data configuration, not the retired /vault/data.
  python3 - "${root}/README.md" <<'PY'
import sys

text = open(sys.argv[1]).read()
for needle in (
    'bao operator raft snapshot save',
    'openbao-raft.snap',
    '/openbao/data',
    'bao operator raft snapshot restore -force',
    'bao operator raft list-peers',
    'sealed: false',
):
    assert needle in text, f'README OpenBao recovery section missing: {needle!r}'
assert '/vault/data' not in text, \
    'README must not reference the retired /vault/data Raft path'
PY
}

main "$@"
