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
}

main "$@"
