#!/usr/bin/env bash
# Create or update OpenBao AppRoles with short-lived, single-use wrapped SecretIDs.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck source=scripts/lib/common.sh
source "${PROJECT_ROOT}/scripts/lib/common.sh"
common::load_config "${PROJECT_ROOT}/config.env"
# shellcheck source=scripts/lib/openbao.sh
source "${PROJECT_ROOT}/scripts/lib/openbao.sh"

BACKUP_DIR="${OPENBAO_BACKUP_DIR}"
TOKEN_TTL="30m"
TOKEN_MAX_TTL="2h"
SECRET_ID_TTL="30m"
WRAP_TTL="5m"

usage() {
  cat <<USAGE
Usage:
  bash scripts/openbao/create-approle.sh <role-name> <policy> [options]

Options:
  --token-ttl=<duration>       Default: 30m
  --token-max-ttl=<duration>   Default: 2h
  --secret-id-ttl=<duration>   Default: 30m
  --wrap-ttl=<duration>        Default: 5m
USAGE
}

if [ $# -lt 2 ]; then
  usage
  exit 1
fi

ROLE_NAME="$1"
POLICY="$2"
shift 2

while [ $# -gt 0 ]; do
  case "$1" in
    --token-ttl=*) TOKEN_TTL="${1#*=}" ;;
    --token-max-ttl=*) TOKEN_MAX_TTL="${1#*=}" ;;
    --secret-id-ttl=*) SECRET_ID_TTL="${1#*=}" ;;
    --wrap-ttl=*) WRAP_TTL="${1#*=}" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
  shift
done

if ! [[ "$ROLE_NAME" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "ERROR: Role name must match ^[A-Za-z0-9._-]+$" >&2
  exit 1
fi

if ! [[ "$POLICY" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "ERROR: Policy must match ^[A-Za-z0-9._-]+$" >&2
  exit 1
fi

mkdir -p "$BACKUP_DIR/approles"

ROOT_TOKEN="$(openbao::load_root_token)"


if ! kubectl get pod "$OPENBAO_POD" -n "$OPENBAO_NS" >/dev/null 2>&1; then
  echo "ERROR: OpenBao pod '$OPENBAO_POD' not found in namespace '$OPENBAO_NS'." >&2
  exit 1
fi

kubectl wait --for=condition=Ready "pod/${OPENBAO_POD}" -n "$OPENBAO_NS" --timeout=300s >/dev/null
openbao::exec token lookup

if ! openbao::exec_quiet auth list -format=json | python3 -c "import json,sys; print('approle/' in json.load(sys.stdin))" 2>/dev/null | grep -q True; then
  echo "ERROR: approle auth is not enabled. Run bootstrap first." >&2
  exit 1
fi

if ! openbao::exec policy read "$POLICY"; then
  echo "ERROR: Policy '$POLICY' does not exist." >&2
  exit 1
fi

echo "=== Ensuring AppRole '$ROLE_NAME' ==="
openbao::exec write auth/approle/role/"${ROLE_NAME}" \
  "token_policies=${POLICY}" \
  "token_ttl=${TOKEN_TTL}" \
  "token_max_ttl=${TOKEN_MAX_TTL}" \
  "secret_id_ttl=${SECRET_ID_TTL}" \
  secret_id_num_uses=1 >/dev/null

echo "  Role configured with policy: $POLICY"
ROLE_ID="$(openbao::exec read -field=role_id auth/approle/role/"$ROLE_NAME"/role-id)"
WRAP_JSON="$(openbao::exec write -format=json -wrap-ttl="$WRAP_TTL" -f auth/approle/role/"$ROLE_NAME"/secret-id)"
WRAPPING_TOKEN="$(printf '%s\n' "$WRAP_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['wrap_info']['token'])")"
WRAPPING_ACCESSOR="$(printf '%s\n' "$WRAP_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['wrap_info'].get('accessor',''))")"

OUTPUT_FILE="$BACKUP_DIR/approles/${ROLE_NAME}.json"
python3 - <<PY > "$OUTPUT_FILE"
import json
print(json.dumps({
  "role_name": "$ROLE_NAME",
  "policy": "$POLICY",
  "role_id": "$ROLE_ID",
  "wrapped_secret_id_token": "$WRAPPING_TOKEN",
  "wrapped_secret_id_accessor": "$WRAPPING_ACCESSOR",
  "wrap_ttl": "$WRAP_TTL",
  "secret_id_ttl": "$SECRET_ID_TTL",
  "secret_id_num_uses": 1,
  "token_ttl": "$TOKEN_TTL",
  "token_max_ttl": "$TOKEN_MAX_TTL",
  "secret_id_stored_in_kv": False
}, indent=2))
PY
chmod 600 "$OUTPUT_FILE"

echo "  RoleID and wrapped SecretID saved to: $OUTPUT_FILE"
echo "  SecretID is response-wrapped. Unwrap within $WRAP_TTL."
echo "OpenBao AppRole creation complete."
