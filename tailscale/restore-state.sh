#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BACKUP_ROOT="${TAILSCALE_BACKUP_DIR:-${REPO_ROOT}/.runtime-backups/tailscale}"
BACKUP_DIR="${1:-latest}"

if [ "$BACKUP_DIR" = "latest" ]; then
  if [ ! -d "$BACKUP_ROOT" ]; then
    echo "No Tailscale backup root found: ${BACKUP_ROOT}" >&2
    exit 1
  fi
  BACKUP_DIR=$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n 1 | cut -d' ' -f2- || true)
  if [ -z "$BACKUP_DIR" ]; then
    echo "No Tailscale backups found under: ${BACKUP_ROOT}" >&2
    exit 1
  fi
fi

if [ ! -d "$BACKUP_DIR" ]; then
  echo "Backup directory does not exist: ${BACKUP_DIR}" >&2
  exit 1
fi

sanitize_secret_json() {
  python3 - "$1" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path) as f:
    doc = json.load(f)

metadata = doc.setdefault("metadata", {})
for field in ("creationTimestamp", "resourceVersion", "uid", "managedFields", "selfLink", "ownerReferences"):
    metadata.pop(field, None)
doc.pop("status", None)
json.dump(doc, sys.stdout)
PY
}

restore_secret() {
  local file="$1"
  local name="$2"

  if [ ! -f "$file" ]; then
    echo "    ⚠ ${name} backup not found at ${file}; skipping."
    return 0
  fi

  echo "    Restoring ${name}..."
  sanitize_secret_json "$file" | kubectl apply -f -
  echo "    ✓ ${name} restored."
}

validate_operator_identity() {
  local file="${BACKUP_DIR}/operator.json"
  if [ ! -f "$file" ]; then
    echo "    ⚠ operator.json is missing; cannot validate operator machine identity."
    return 0
  fi

  local keys
  keys=$(python3 - "$file" <<'PY'
import json
import sys
with open(sys.argv[1]) as f:
    doc = json.load(f)
keys = [k for k in (doc.get('data') or {}) if k.startswith('_machinekey') or k.startswith('_current-profile') or k.startswith('profile-')]
print(' '.join(keys))
PY
)

  if [ -z "$keys" ]; then
    echo "    ⚠ operator.json does not contain _machinekey/_current-profile/profile-* identity keys."
    echo "      Restoring it may not prevent a new operator device registration."
  else
    echo "    ✓ operator identity keys found: ${keys}"
  fi
}

echo "=== Restoring Tailscale Kubernetes state ==="
echo "Backup path: ${BACKUP_DIR}"
echo "IMPORTANT: Run this before installing/starting the Tailscale operator on a rebuilt cluster."

kubectl create namespace tailscale --dry-run=client -o yaml | kubectl apply -f -

validate_operator_identity
restore_secret "${BACKUP_DIR}/operator-oauth.json" "operator-oauth Secret"
restore_secret "${BACKUP_DIR}/operator.json" "operator identity Secret"

cat <<EOF
=== Restore Complete ===
Next step: run ./setup.sh or ./tailscale/install-operator.sh.
If the operator was already started before this restore, check the Tailscale admin console for a newly-created duplicate and remove the stale/extra device after confirming the active one.
EOF
