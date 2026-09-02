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
  # Placeholder tokens must be renderable by cluster::render_config.
  grep -q 'KIND_API_SERVER_ADDRESS_PLACEHOLDER' "${kind_config}"
  grep -q 'TAILSCALE_VPS_IP_PLACEHOLDER' "${kind_config}"
  local rendered_kind_config TAILSCALE_VPS_IP=100.71.197.26
  cluster::render_config rendered_kind_config "${kind_config}"
  grep -q 'apiServerAddress: "100.71.197.26"' "${rendered_kind_config}"
  if grep -q 'PLACEHOLDER' "${rendered_kind_config}"; then
    echo "ERROR: rendered kind config contains an unresolved placeholder" >&2
    return 1
  fi

  # P1: destructive kind lifecycle operations must be bound to CLUSTER_NAME
  # shellcheck disable=SC2016 # literal pattern; $CLUSTER_NAME must stay unexpanded
  if grep -n 'kind delete cluster' "${root}/scripts/commands/cluster.sh" | grep -v -- '--name "$CLUSTER_NAME"' >/dev/null; then
    echo "ERROR: kind delete not bound to CLUSTER_NAME" >&2
    return 1
  fi

  # Production deploys pin Flux to the immutable release tag; local bootstrap
  # remains branch-main. Neither path may mutate the source with a patch.
  python3 - "${root}/scripts/lib/flux.sh" "${root}/.github/workflows/IaC.yml" <<'PY'
import sys

source = open(sys.argv[1]).read()
assert 'FLUX_GIT_TAG' not in source, \
    'Flux must not implement runtime semver ref switching'
assert '--tag-semver' not in source, \
    'Flux must not create semver-tag sources'
assert 'kubectl patch gitrepository' not in source, \
    'Flux must not merge-patch GitRepository spec.ref'
assert '--branch="${FLUX_GITHUB_BRANCH}"' in source, \
    'Flux bootstrap must pin the configured branch'

ci = open(sys.argv[2]).read()
assert 'semver:' not in ci and '--tag-semver' not in ci, \
    'CI deploy must not configure a moving semver source'
assert 'tag: ${RELEASE_TAG}' in ci and 'RELEASE_SHA: ${{ github.sha }}' in ci, \
    'CI deploy must declare and verify its immutable release source'
assert 'kubectl patch gitrepository flux-system' not in ci, \
    'CI must not merge-patch GitRepository spec.ref'
assert 'tailscale ping --until-direct=false --c=1 --timeout=10s "${host}" || true' in ci, \
    'TSMP ping must remain diagnostic; TCP and kubectl determine API reachability'
PY

  # P1: the branch selector belongs exclusively to the bootstrap source
  # (branch-main decision 2026-08-31). Flux never merge-patches refs and
  # never recreates the source with a different selector at runtime.
  python3 - "${root}/scripts/lib/flux.sh" <<'PY'
import sys

source = open(sys.argv[1]).read()

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
PY

  # Branch-main convergence + stage-5 guard (audit v2 follow-up, 2026-09-01):
  # 'make up' must converge the flux-system source to the configured branch
  # (a cluster bootstrapped from a temporary bootstrap branch would otherwise
  # keep fetching that branch forever), then verify the Flux GitRepository
  # artifact matches git HEAD before waiting on layer readiness. A stale
  # source previously let every layer report Ready on the last-good artifact
  # while new manifests (platform/tailscale) never applied — surfacing only
  # as the opaque "HelmRelease tailscale-operator not found" failure.
  python3 - "${root}/scripts/lib/flux.sh" "${root}/scripts/commands/cluster.sh" <<'PY'
import sys

lib, cmd = (open(p).read() for p in sys.argv[1:3])

assert 'flux::converge_source()' in lib, \
    'flux.sh must define the branch-main source convergence'
conv = lib[lib.index('flux::converge_source()'):lib.index('flux::verify_source_sync()')]
assert 'branch: ${branch}' in conv and 'ref:' in conv, \
    'convergence must declare the GitRepository branch ref idempotently'
assert 'git@github.com:*' in conv, \
    'SSH origins must be normalized to unauthenticated HTTPS fetch'
assert 'condition=Ready' in conv, \
    'convergence must wait for the repointed source to sync'

assert 'flux::verify_source_sync()' in lib, \
    'flux.sh must define the source-sync verification'
fn = lib[lib.index('flux::verify_source_sync()'):lib.index('flux::bootstrap_or_apply()')]
assert 'rev-parse HEAD' in fn, \
    'verification must resolve the checked-out git HEAD'
assert 'status.artifact.revision' in fn, \
    'verification must compare the GitRepository artifact revision'
assert 'common::die' in fn, \
    'verification must fail loudly on a stale or missing artifact'

main = cmd[cmd.index('main()'):]
assert main.index('flux::bootstrap_or_apply') < \
       main.index('flux::converge_source') < \
       main.index('flux::verify_source_sync') < \
       main.index('kubectl wait --for=condition=Ready'), \
    'make up must converge then verify the source after bootstrap, before layer waits'
PY

  # P1: Tailscale helpers must define every symbol the command layer calls,
  # and the verification flow must deliver the OAuth Secret before
  # verifying the Flux-managed operator (Flux owns the install itself).
  python3 - "${root}/scripts/commands/tailscale.sh" "${root}/scripts/lib/tailscale.sh" <<'PY'
import re
import sys

cmd, lib = open(sys.argv[1]).read(), open(sys.argv[2]).read()

# Every tailscale:: symbol called from the command layer must be defined.
calls = set(re.findall(r'tailscale::([a-z_0-9]+)', cmd))
defs = set(re.findall(r'tailscale::([a-z_0-9]+)\(\)', lib))
missing = calls - defs
assert not missing, f'undefined Tailscale symbols: {sorted(missing)}'

# Ordering: OAuth Secret delivery must appear before install_operator
# (Flux owns the install; the shell delivers the Secret and verifies).
cmd_main = cmd[cmd.index('main()'):]
assert cmd_main.index('tailscale::ensure_deploy_secret') < \
       cmd_main.index('tailscale::install_operator'), \
    'Tailscale verification ordering must be Secret delivery -> operator verify'

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
