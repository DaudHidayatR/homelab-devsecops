#!/usr/bin/env bash
# OpenBao diagnostic status script.
# Read-only and safe to run against uninitialized, sealed, or unsealed clusters.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck source=scripts/lib/common.sh
source "${PROJECT_ROOT}/scripts/lib/common.sh"
common::load_config "${PROJECT_ROOT}/config.env"
# shellcheck source=scripts/lib/openbao.sh
source "${PROJECT_ROOT}/scripts/lib/openbao.sh"

BACKUP_DIR="${OPENBAO_BACKUP_DIR}"

_bao_exec() {
  openbao::exec "$@"
}

_bao_exec_quiet() {
  openbao::exec_quiet "$@"
}

print_section() {
  echo ""
  echo "=== $1 ==="
}

if ! kubectl get pod "$OPENBAO_POD" -n "$OPENBAO_NS" >/dev/null 2>&1; then
  echo "OpenBao pod '$OPENBAO_POD' not found in namespace '$OPENBAO_NS'."
  exit 0
fi

print_section "Pod"
kubectl get pod "$OPENBAO_POD" -n "$OPENBAO_NS"

print_section "Seal Status"
STATUS_JSON="$(_bao_exec_quiet "bao status -format=json")"
if [ -z "$STATUS_JSON" ]; then
  echo "Unable to read OpenBao status. Pod may not be ready."
  exit 0
fi
printf '%s\n' "$STATUS_JSON" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    print("Unable to parse status JSON")
    sys.exit(0)
for key in ("initialized", "sealed", "version", "storage_type", "cluster_name", "cluster_id"):
    if key in data:
        print(f"{key}: {data[key]}")
' || true

INITIALIZED=$(printf '%s\n' "$STATUS_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin).get('initialized', False))" 2>/dev/null || echo False)
SEALED=$(printf '%s\n' "$STATUS_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin).get('sealed', True))" 2>/dev/null || echo True)

if [ "$INITIALIZED" != "True" ] || [ "$SEALED" = "True" ]; then
  echo "OpenBao is not initialized or is sealed; skipping authenticated diagnostics."
  exit 0
fi

if [ -z "${OPENBAO_TOKEN:-}" ] && [ -f "$BACKUP_DIR/root-token.txt" ]; then
  OPENBAO_TOKEN="$(tr -d '\n' < "$BACKUP_DIR/root-token.txt")"
fi

if [ -z "${OPENBAO_TOKEN:-}" ]; then
  echo "OPENBAO_TOKEN not set and no root token backup found at $BACKUP_DIR/root-token.txt."
  echo "Skipping authenticated diagnostics."
  exit 0
fi

print_section "Auth Methods"
_bao_exec "bao auth list" || true

print_section "Secrets Engines"
_bao_exec "bao secrets list" || true

print_section "Audit Devices"
_bao_exec "bao audit list" || true

print_section "Policies"
_bao_exec "bao policy list" || true

print_section "Kubernetes Roles"
_bao_exec "bao list auth/kubernetes/role" || true

print_section "Entities"
_bao_exec "bao list identity/entity/name" || true

print_section "Current Token"
_bao_exec "bao token lookup" || true
