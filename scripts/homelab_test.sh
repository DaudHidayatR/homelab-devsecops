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

kubectl() {
  case "$1 $2" in
    "config view")
      if [[ "$4" == *'.contexts['* ]]; then
        printf 'kind-%s' "${CLUSTER_NAME}"
      else
        printf 'https://0.0.0.0:6443'
      fi
      ;;
    "config set-cluster") KUBECONFIG_SERVER_ARG="$4" ;;
    *) return 1 ;;
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
  local source_config KIND_CONFIG KUBECONFIG_SERVER_ARG
  common::mktemp_var source_config /tmp/kind-source.XXXXXX.yaml
  printf 'kind: Cluster\n' >"${source_config}"
  cluster::ensure_kind "${source_config}"
  [[ "${KIND_CONFIG}" != "${source_config}" ]]
  cmp -s "${source_config}" "${KIND_CONFIG}"
  [[ "${KUBECONFIG_SERVER_ARG}" == "--server=https://127.0.0.1:6443" ]]

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

  # P1: the local Flux ref must carry exactly one selector. Semver mode
  # recreates the source with only --tag-semver, never merging --branch into
  # the same spec.ref, and never merge-patching the existing object (which
  # would retain a stale branch/tag/commit key next to semver).
  python3 - "${root}/scripts/lib/flux.sh" <<'PY'
import sys

source = open(sys.argv[1]).read()

# The semver recreate block must not also pass --branch: spec.ref must carry
# exactly one selector (semver), replacing the branch selector entirely.
semver_block = source[source.index('--tag-semver='):source.index('--interval=1m')]
assert '--branch=' not in semver_block, \
    'Flux semver switch must not pass --branch alongside --tag-semver'

# A merge-patch (--type merge) that only sets spec.ref.semver would retain a
# stale branch key from the existing object; the recreate path must not use it.
assert '--type merge' not in source, \
    'Flux semver switch must replace spec.ref atomically, never merge keys'

# The branch selector belongs exclusively to the initial bootstrap, where it
# is the single selector for the fresh ref created by flux bootstrap.
bootstrap_args = source[source.index('flux bootstrap github'):source.index('--personal')]
assert '--branch=' in bootstrap_args, \
    'Flux bootstrap must keep its single branch selector'

assert 'FLUX_BOOTSTRAP_MODE:=auto' in source, \
    'Flux must default to the protected-branch-safe auto mode'
assert source.index('kubectl get deployment source-controller') < source.index('flux bootstrap github'), \
    'Flux must reuse an existing installation before considering GitHub bootstrap'
assert 'kubectl apply -k' in source and '/flux-system' in source, \
    'Flux must install committed bootstrap manifests without a GitHub push'
assert 'elif [[ "${FLUX_BOOTSTRAP_MODE}" == github ]]' in source, \
    'Direct GitHub bootstrap must require explicit opt-in'
assert 'git ls-remote --exit-code --heads' in source, \
    'GitHub bootstrap must check whether its target branch exists'
assert 'repos/${GITHUB_USER}/${FLUX_GITHUB_REPOSITORY}/git/refs' in source, \
    'GitHub bootstrap must create a missing target branch before Flux clones it'
assert source.index('git/refs') < source.index('flux bootstrap github', source.index('elif [[ "${FLUX_BOOTSTRAP_MODE}" == github ]]')), \
    'A missing bootstrap branch must be created before Flux bootstrap runs'
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

  # P1: the recovery contract is pinned to operator + optional OAuth only.
  # Proxy (ts-*) identities are intentionally NOT restored: restore must not
  # read or apply all-secrets.json or any ts-* secret, must fail clearly when
  # a backup dir has proxy data but no valid operator.json, and the docs must
  # say so explicitly in both READMEs.
  python3 - "${root}/scripts/commands/tailscale.sh" "${root}/scripts/lib/tailscale.sh" \
    "${root}/README.md" "${root}/scripts/README.md" <<'PY'
import re
import sys

cmd, lib, readme, scripts_readme = (open(p).read() for p in sys.argv[1:5])

restore = cmd[cmd.index('command_tailscale_restore()'):]
restore = restore[:restore.index('command=')]

# Restore may read only operator.json (required) and operator-oauth.json
# (optional) from the backup directory. all-secrets.json may appear at most
# once, and only as an existence check that fails the restore.
refs = re.findall(r'\$\{BACKUP_DIR\}/[^\s"\']+', restore)
allowed = {'${BACKUP_DIR}/operator.json', '${BACKUP_DIR}/operator-oauth.json'}
unexpected = [r for r in refs if r not in allowed]
assert unexpected == [] or unexpected == ['${BACKUP_DIR}/all-secrets.json'], \
    f'restore reads unexpected backup files: {unexpected}'
assert refs.count('${BACKUP_DIR}/all-secrets.json') <= 1, \
    'all-secrets.json may appear only as a fail-clear existence check'

# The only kubectl apply in restore is the optional operator-oauth pipe
# (the required operator.json apply lives in restore_operator_identity).
applies = re.findall(r'kubectl apply[^\n]*', restore)
assert len(applies) == 1 and applies[0].strip() == 'kubectl apply -f -', \
    f'restore must contain exactly one piped kubectl apply, got: {applies}'
assert 'python3 - "${BACKUP_DIR}/operator-oauth.json" <<' in restore, \
    'the single apply must be the operator-oauth pipe (python3 -> kubectl apply)'

# ts-* may appear only in explanatory "not restored by design" prose, never
# as a read/apply target.
ts_lines = [line for line in restore.splitlines() if 'ts-' in line]
assert ts_lines and all('not restored by design' in line for line in ts_lines), \
    'ts-* may appear only in the not-restored-by-design explanation'

# Fail-before-partial: a backup dir with proxy data but no valid
# operator.json must abort with a clear non-secret message.
assert 'Backup contains only all-secrets.json' in cmd, \
    'restore must fail clearly when only all-secrets.json is present'

# OAuth input is validated at the boundary before any apply.
assert 'tailscale::validate_oauth_file' in cmd and 'tailscale::validate_oauth_file()' in lib, \
    'operator-oauth.json must be validated before restore applies it'
assert 'client_id' in lib and 'client_secret' in lib, \
    'validate_oauth_file must require client_id and client_secret'

# Docs must narrow the contract explicitly (both READMEs).
for text, name in ((readme, 'README.md'), (scripts_readme, 'scripts/README.md')):
    assert 'not restored' in text and 'ts-' in text, \
        f'{name} must state explicitly that ts-* proxy identities are not restored'
assert 'all-secrets.json' in scripts_readme and 'not consumed by recovery' in scripts_readme, \
    'scripts/README.md must document all-secrets.json as not consumed by recovery'
assert 'all-secrets.json' in readme and 'forensic' in readme, \
    'README.md must document all-secrets.json as a forensic snapshot'
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

  # P1: the CI deploy job must not persist a GitHub token for the public
  # flux-system source. The GitRepository is fetched unauthenticated over
  # HTTPS, so no GITHUB_TOKEN is written into a flux-system secret and no
  # secretRef is attached to the source.
  python3 - "${root}/.github/workflows/IaC.yml" <<'PY'
import re
import sys

text = open(sys.argv[1]).read()
if 'GIT_TOKEN: ${{ github.token }}' in text:
    raise AssertionError('CI deploy job must not persist github.token')
if re.search(r'kubectl create secret generic flux-system[^\n]*', text):
    raise AssertionError('CI deploy job must not create a flux-system secret')
if re.search(r'kubectl apply -f - <<EOF.*?secretRef:\n\s+name: flux-system',
             text, re.S):
    raise AssertionError('flux-system GitRepository must not carry secretRef')
assert 'kubectl delete secret flux-system -n flux-system --ignore-not-found' in text, \
    'CI deploy job must drop stale flux-system token secrets'
PY
}

main "$@"
