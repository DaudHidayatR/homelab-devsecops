#!/usr/bin/env bash
# Create or update OpenBao userpass users and optional per-user SSH signing roles.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck source=scripts/lib/common.sh
source "${PROJECT_ROOT}/scripts/lib/common.sh"
common::load_config "${PROJECT_ROOT}/config.env"
# shellcheck source=scripts/lib/openbao.sh
source "${PROJECT_ROOT}/scripts/lib/openbao.sh"

BACKUP_DIR="${OPENBAO_BACKUP_DIR}"
DEFAULT_POLICY="user-default"
SSH_ENABLED="false"

usage() {
  cat <<USAGE
Usage:
  bash scripts/openbao/create-user.sh <username> <password> [policy[,policy...]] [--ssh]

Examples:
  bash scripts/openbao/create-user.sh alice 'change-me' user-default
  bash scripts/openbao/create-user.sh alice 'change-me' user-default --ssh
  bash scripts/openbao/create-user.sh sagash 'change-me' user-default,system-admin,user-ssh --ssh
USAGE
}

if [ $# -lt 2 ]; then
  usage
  exit 1
fi

USERNAME="$1"
PASSWORD="$2"
POLICIES="${3:-$DEFAULT_POLICY}"
shift 2
if [ $# -gt 0 ] && [ "${1:-}" != "--ssh" ]; then
  POLICIES="$1"
  shift
fi
while [ $# -gt 0 ]; do
  case "$1" in
    --ssh) SSH_ENABLED="true" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
  shift
done

if ! [[ "$USERNAME" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "ERROR: Username must match ^[A-Za-z0-9._-]+$" >&2
  exit 1
fi

if ! [[ "$POLICIES" =~ ^[A-Za-z0-9._-]+(,[A-Za-z0-9._-]+)*$ ]]; then
  echo "ERROR: Policies must be a comma-separated list matching ^[A-Za-z0-9._-]+(,[A-Za-z0-9._-]+)*$" >&2
  exit 1
fi

IFS=',' read -r -a POLICY_LIST <<< "$POLICIES"

mkdir -p "$BACKUP_DIR/users"

ROOT_TOKEN="$(openbao::load_root_token)"

_bao_exec() {
  openbao::exec "$@"
}

_bao_exec_quiet() {
  openbao::exec_quiet "$@"
}

json_escape() {
  python3 -c 'import json,sys; print(json.dumps(sys.stdin.read())[1:-1])'
}

PASSWORD_ESCAPED="$(printf '%s' "$PASSWORD" | json_escape)"

if ! kubectl get pod "$OPENBAO_POD" -n "$OPENBAO_NS" >/dev/null 2>&1; then
  echo "ERROR: OpenBao pod '$OPENBAO_POD' not found in namespace '$OPENBAO_NS'." >&2
  exit 1
fi

kubectl wait --for=condition=Ready "pod/${OPENBAO_POD}" -n "$OPENBAO_NS" --timeout=300s >/dev/null
_bao_exec "bao token lookup >/dev/null"

if ! _bao_exec_quiet "bao auth list -format=json" | python3 -c "import json,sys; print('userpass/' in json.load(sys.stdin))" 2>/dev/null | grep -q True; then
  echo "ERROR: userpass auth is not enabled. Run bootstrap first." >&2
  exit 1
fi

for policy in "${POLICY_LIST[@]}"; do
  if ! _bao_exec_quiet "bao policy read '$policy' >/dev/null 2>&1"; then
    echo "ERROR: Policy '$policy' does not exist." >&2
    exit 1
  fi
done

echo "=== Ensuring userpass user '$USERNAME' ==="
_bao_exec "bao write auth/userpass/users/'$USERNAME' password='$PASSWORD_ESCAPED' policies='$POLICIES' token_ttl='1h' token_max_ttl='4h'" >/dev/null
echo "  Userpass user configured with policies: $POLICIES"

ACCESSOR="$(_bao_exec "bao read -field=accessor sys/auth/userpass")"
ENTITY_NAME="user-${USERNAME}"

if _bao_exec "bao read identity/entity/name/'$ENTITY_NAME' >/dev/null 2>&1"; then
  ENTITY_ID="$(_bao_exec "bao read -field=id identity/entity/name/'$ENTITY_NAME'")"
  _bao_exec "bao write identity/entity/id/'$ENTITY_ID' \
    policies='$POLICIES' \
    metadata=managed_by='openbao-create-user' \
    metadata=username='$USERNAME' \
    metadata=policy='$POLICIES' \
    metadata=policies='$POLICIES' \
    metadata=ssh_enabled='$SSH_ENABLED'" >/dev/null
else
  ENTITY_ID="$(_bao_exec "bao write -field=id identity/entity \
    name='$ENTITY_NAME' \
    policies='$POLICIES' \
    metadata=managed_by='openbao-create-user' \
    metadata=username='$USERNAME' \
    metadata=policy='$POLICIES' \
    metadata=policies='$POLICIES' \
    metadata=ssh_enabled='$SSH_ENABLED'")"
fi

echo "  Entity: $ENTITY_NAME ($ENTITY_ID)"

_bao_exec "bao write identity/entity-alias \
  name='$USERNAME' \
  canonical_id='$ENTITY_ID' \
  mount_accessor='$ACCESSOR'" >/dev/null || true
echo "  Alias: $USERNAME -> $ENTITY_ID"

_bao_exec "bao kv put 'secret/users/${ENTITY_ID}/profile' \
  username='$USERNAME' \
  policy='$POLICIES' \
  policies='$POLICIES' \
  ssh_enabled='$SSH_ENABLED' \
  managed_by='openbao-create-user'" >/dev/null
echo "  Stored non-sensitive metadata at secret/users/${ENTITY_ID}/profile"

if [ "$SSH_ENABLED" = "true" ]; then
  if _bao_exec_quiet "bao secrets list -format=json" | python3 -c "import json,sys; print('ssh-client-signer/' in json.load(sys.stdin))" 2>/dev/null | grep -q True; then
    _bao_exec "bao write ssh-client-signer/roles/'$ENTITY_ID' \
      algorithm_signer='rsa-sha2-256' \
      allow_user_certificates=true \
      allowed_users='$USERNAME' \
      default_user='$USERNAME' \
      key_type='ca' \
      ttl='1h'" >/dev/null
    echo "  SSH role: ssh-client-signer/roles/$ENTITY_ID (allowed_users=$USERNAME)"
  else
    echo "  WARNING: ssh-client-signer/ secrets engine is not enabled; SSH role not created."
  fi
fi

USER_BACKUP="$BACKUP_DIR/users/${USERNAME}.json"
python3 - <<PY > "$USER_BACKUP"
import json
print(json.dumps({
  "username": "$USERNAME",
  "entity_name": "$ENTITY_NAME",
  "entity_id": "$ENTITY_ID",
  "policy": "$POLICIES",
  "policies": "$POLICIES",
  "ssh_enabled": "$SSH_ENABLED" == "true",
  "password_stored_in_kv": False
}, indent=2))
PY
chmod 600 "$USER_BACKUP"
echo "  Local metadata backup: $USER_BACKUP"
echo "OpenBao user creation complete."
