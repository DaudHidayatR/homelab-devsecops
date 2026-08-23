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
}

main "$@"
