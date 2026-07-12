#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${PROJECT_ROOT}/scripts/lib/common.sh"
common::load_config "${PROJECT_ROOT}/config.env"
# shellcheck source=scripts/lib/tailscale.sh
source "${PROJECT_ROOT}/scripts/lib/tailscale.sh"

BACKUP_DIR="${1:-}"
[[ -n "${BACKUP_DIR}" ]] || common::die "Usage: $0 <validated-backup-directory>"
[[ -d "${BACKUP_DIR}" ]] || common::die "Backup directory does not exist: ${BACKUP_DIR}"
! k8s::deployment_exists "${TAILSCALE_NAMESPACE}" "${TAILSCALE_OPERATOR_DEPLOYMENT}" || common::die "Refusing to patch identity after the Tailscale operator has started."

tailscale::ensure_namespace
tailscale::restore_operator_identity "${BACKUP_DIR}/operator.json"
if [[ -s "${BACKUP_DIR}/operator-oauth.json" ]]; then
  python3 - "${BACKUP_DIR}/operator-oauth.json" <<'PY' | kubectl apply -f -
import json, sys
d = json.load(open(sys.argv[1]))
m = d.setdefault('metadata', {})
for key in ('creationTimestamp','resourceVersion','uid','managedFields','selfLink','ownerReferences'):
    m.pop(key, None)
m['namespace'] = 'tailscale'
d.pop('status', None)
json.dump(d, sys.stdout)
PY
fi

k8s::secret_exists "${TAILSCALE_NAMESPACE}" "${TAILSCALE_OPERATOR_SECRET}" || common::die "Restored operator identity Secret is absent."
log::success "Validated Tailscale identity restored before operator startup."
