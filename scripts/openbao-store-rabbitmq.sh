#!/usr/bin/env bash
# Store RabbitMQ credentials in OpenBao KV v2.
#
# Prerequisites:
#   OpenBao must be initialized, unsealed, and ready.
#   Run scripts/openbao-bootstrap.sh first if not yet bootstrapped.
#
# Usage:
#   bash scripts/openbao-store-rabbitmq.sh
#
# If a RabbitMQ credentials secret already exists in Kubernetes, it copies
# those values into OpenBao. Otherwise, generates a new random password.

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="${SCRIPT_DIR}/../.runtime-backups/openbao"
OPENBAO_POD="openbao-0"
OPENBAO_NS="openbao"
RABBITMQ_NS="messaging"
SECRET_NAME="rabbitmq-credentials"
# CLI path for the KV v2 mount. The underlying API path is
# secret/data/messaging/rabbitmq, while ESO remoteRef.key is messaging/rabbitmq.
SECRET_PATH="secret/messaging/rabbitmq"

# ── Helpers ────────────────────────────────────────────────────────────

_bao_exec() {
  kubectl exec -n "$OPENBAO_NS" "$OPENBAO_POD" -- sh -c "
    export BAO_ADDR='https://127.0.0.1:8200'
    export BAO_SKIP_VERIFY=true
    $*"
}

_bao_exec_quiet() {
  _bao_exec "$@" 2>/dev/null || true
}

# ── 1. Verify OpenBao is ready ────────────────────────────────────────

echo "=== OpenBao RabbitMQ Secret Storage ==="
echo ""

if ! kubectl get pod "$OPENBAO_POD" -n "$OPENBAO_NS" &>/dev/null; then
  echo "ERROR: OpenBao pod not found. Run 'make up' first."
  exit 1
fi

kubectl wait --for=condition=Ready "pod/${OPENBAO_POD}" -n "$OPENBAO_NS" --timeout=120s

# Check if OpenBao is initialized and unsealed
STATUS_JSON=$(_bao_exec_quiet "bao status -format=json")
INITIALIZED=$(echo "$STATUS_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin).get('initialized',False))" 2>/dev/null || echo "False")
SEALED=$(echo "$STATUS_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin).get('sealed',True))" 2>/dev/null || echo "True")

if [ "$INITIALIZED" != "True" ]; then
  echo "ERROR: OpenBao is not initialized. Run scripts/openbao-bootstrap.sh first."
  exit 1
fi

if [ "$SEALED" = "True" ]; then
  echo "ERROR: OpenBao is sealed. Unseal it first."
  exit 1
fi

# Login as root
if [ ! -f "$BACKUP_DIR/root-token.txt" ]; then
  echo "ERROR: Root token not found at $BACKUP_DIR/root-token.txt"
  exit 1
fi
ROOT_TOKEN=$(cat "$BACKUP_DIR/root-token.txt")
_bao_exec_quiet "bao login '$ROOT_TOKEN'" >/dev/null
echo "  Authenticated to OpenBao."

# ── 2. Determine credentials ──────────────────────────────────────────

echo ""
echo "=== Gathering RabbitMQ credentials ==="

USER="admin"
PASS=""

# Prefer existing Kubernetes secret
if kubectl get secret "$SECRET_NAME" -n "$RABBITMQ_NS" &>/dev/null; then
  echo "  Found existing Kubernetes secret '$SECRET_NAME' in namespace '$RABBITMQ_NS'."
  PASS=$(kubectl get secret "$SECRET_NAME" -n "$RABBITMQ_NS" \
    -o jsonpath='{.data.RABBITMQ_DEFAULT_PASS}' | base64 -d)

  # Also check for an existing user value (some setups use custom users)
  EXISTING_USER=$(kubectl get secret "$SECRET_NAME" -n "$RABBITMQ_NS" \
    -o jsonpath='{.data.RABBITMQ_DEFAULT_USER}' | base64 -d 2>/dev/null || echo "")
  if [ -n "$EXISTING_USER" ] && [ "$EXISTING_USER" != "admin" ]; then
    USER="$EXISTING_USER"
  fi

  echo "  Migrating existing credentials (user: $USER) into OpenBao."
else
  echo "  No existing Kubernetes secret found. Generating new credentials."
  PASS=$(openssl rand -base64 32 | tr -d '\n')
  echo "  Generated random password for RabbitMQ."
fi

# ── 3. Check if already stored in OpenBao ─────────────────────────────

EXISTS_IN_OBAO=$(_bao_exec_quiet "bao kv get -format=json '$SECRET_PATH'" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print('true' if d.get('data',{}).get('data',{}).get('RABBITMQ_DEFAULT_USER') else 'false')
" 2>/dev/null || echo "false")

if [ "$EXISTS_IN_OBAO" = "true" ]; then
  echo ""
  echo "  Secret already exists at $SECRET_PATH in OpenBao."
  echo "  Overwrite? [y/N]: "
  read -r ANSWER
  if [ "$ANSWER" != "y" ] && [ "$ANSWER" != "Y" ]; then
    echo "  Skipping. Secret unchanged."
    exit 0
  fi
fi

# ── 4. Store in OpenBao ──────────────────────────────────────────────

echo ""
echo "=== Storing credentials in OpenBao ==="

_bao_exec "bao kv put '$SECRET_PATH' \
  RABBITMQ_DEFAULT_USER='$USER' \
  RABBITMQ_DEFAULT_PASS='$PASS'"

# Verify
echo ""
echo "=== Verifying stored secret ==="
_bao_exec "bao kv get -field=RABBITMQ_DEFAULT_USER '$SECRET_PATH'"
echo "  (password hidden)"

echo ""
echo "═══════════════════════════════════════════"
echo "  RabbitMQ credentials stored in OpenBao."
echo "  Path: $SECRET_PATH"
echo "  KV version: v2"
echo ""
echo "  The External Secrets Operator will sync"
echo "  this to Kubernetes Secret: $RABBITMQ_NS/$SECRET_NAME"
echo "═══════════════════════════════════════════"
