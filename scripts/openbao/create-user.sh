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
  OPENBAO_USER=<username> OPENBAO_PASSWORD=<password> [OPENBAO_POLICY=user-default] [OPENBAO_SSH=true] bash scripts/openbao/create-user.sh
USAGE
}

if [ "$#" -ne 0 ] || [ -z "${OPENBAO_USER:-}" ] || [ -z "${OPENBAO_PASSWORD:-}" ]; then
  usage
  exit 1
fi

USERNAME="${OPENBAO_USER}"
PASSWORD="${OPENBAO_PASSWORD}"
POLICIES="${OPENBAO_POLICY:-$DEFAULT_POLICY}"
case "${OPENBAO_SSH:-false}" in
  true) SSH_ENABLED="true" ;;
  false|"") ;;
  *) echo "ERROR: OPENBAO_SSH must be true or false" >&2; exit 1 ;;
esac

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


if ! kubectl get pod "$OPENBAO_POD" -n "$OPENBAO_NS" >/dev/null 2>&1; then
  echo "ERROR: OpenBao pod '$OPENBAO_POD' not found in namespace '$OPENBAO_NS'." >&2
  exit 1
fi

kubectl wait --for=condition=Ready "pod/${OPENBAO_POD}" -n "$OPENBAO_NS" --timeout=300s >/dev/null
openbao::exec token lookup

if ! openbao::exec_quiet auth list -format=json | python3 -c "import json,sys; print('userpass/' in json.load(sys.stdin))" 2>/dev/null | grep -q True; then
  echo "ERROR: userpass auth is not enabled. Run bootstrap first." >&2
  exit 1
fi

for policy in "${POLICY_LIST[@]}"; do
  if ! openbao::exec_quiet policy read "$policy"; then
    echo "ERROR: Policy '$policy' does not exist." >&2
    exit 1
  fi
done

echo "=== Ensuring userpass user '$USERNAME' ==="
openbao::exec write auth/userpass/users/"${USERNAME}" "password=${PASSWORD}" "policies=${POLICIES}" token_ttl=1h token_max_ttl=4h >/dev/null
echo "  Userpass user configured with policies: $POLICIES"

ACCESSOR="$(openbao::exec read -field=accessor sys/auth/userpass)"
ENTITY_NAME="user-${USERNAME}"

if openbao::exec read identity/entity/name/"$ENTITY_NAME"; then
  ENTITY_ID="$(openbao::exec read -field=id identity/entity/name/"$ENTITY_NAME")"
  openbao::exec write identity/entity/id/"${ENTITY_ID}" \
    "policies=${POLICIES}" \
    metadata=managed_by=openbao-create-user \
    "metadata=username=${USERNAME}" \
    "metadata=policy=${POLICIES}" \
    "metadata=policies=${POLICIES}" \
    "metadata=ssh_enabled=${SSH_ENABLED}" >/dev/null
else
  ENTITY_ID="$(openbao::exec write -field=id identity/entity \
    "name=${ENTITY_NAME}" \
    "policies=${POLICIES}" \
    metadata=managed_by=openbao-create-user \
    "metadata=username=${USERNAME}" \
    "metadata=policy=${POLICIES}" \
    "metadata=policies=${POLICIES}" \
    "metadata=ssh_enabled=${SSH_ENABLED}")"
fi

echo "  Entity: $ENTITY_NAME ($ENTITY_ID)"

openbao::exec write identity/entity-alias \
  "name=${USERNAME}" \
  "canonical_id=${ENTITY_ID}" \
  "mount_accessor=${ACCESSOR}" >/dev/null
echo "  Alias: $USERNAME -> $ENTITY_ID"

openbao::exec kv put secret/users/"${ENTITY_ID}"/profile \
  "username=${USERNAME}" \
  "policy=${POLICIES}" \
  "policies=${POLICIES}" \
  "ssh_enabled=${SSH_ENABLED}" \
  managed_by=openbao-create-user >/dev/null
echo "  Stored non-sensitive metadata at secret/users/${ENTITY_ID}/profile"

if [ "$SSH_ENABLED" = "true" ]; then
  if openbao::exec_quiet secrets list -format=json | python3 -c "import json,sys; print('ssh-client-signer/' in json.load(sys.stdin))" 2>/dev/null | grep -q True; then
    openbao::exec write ssh-client-signer/roles/"${ENTITY_ID}" \
      algorithm_signer=rsa-sha2-256 \
      allow_user_certificates=true \
      "allowed_users=${USERNAME}" \
      "default_user=${USERNAME}" \
      key_type=ca \
      ttl=1h >/dev/null
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
