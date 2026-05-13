#!/usr/bin/env bash
set -euo pipefail

SIGN_CMD=(tailscale lock sign)
if [ "${1:-}" = "--sudo" ]; then
  SIGN_CMD=(sudo tailscale lock sign)
fi

if ! tailscale lock status | grep -q 'Tailnet Lock is ENABLED'; then
  echo "Tailnet Lock is not enabled. No proxy signing required."
  exit 0
fi

mapfile -t PROXY_PODS < <(kubectl get pods -n tailscale \
  -l tailscale.com/managed=true,tailscale.com/parent-resource-type=svc \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)

if [ "${#PROXY_PODS[@]}" -eq 0 ]; then
  echo "No Tailscale proxy pods found."
  exit 0
fi

SIGNED=0
NEEDS_SUDO=0
for pod in "${PROXY_PODS[@]}"; do
  echo "Checking $pod..."
  STATUS_JSON=$(kubectl exec -n tailscale "$pod" -c tailscale -- tailscale status --json 2>/dev/null || true)
  if [ -z "$STATUS_JSON" ]; then
    echo "  Could not read tailscale status. Skipping."
    continue
  fi

  NODE_KEY=$(printf '%s' "$STATUS_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("Self", {}).get("PublicKey", ""))')
  DNS_NAME=$(printf '%s' "$STATUS_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("Self", {}).get("DNSName", ""))')
  HEALTH=$(printf '%s' "$STATUS_JSON" | python3 -c 'import json,sys; print("\n".join(json.load(sys.stdin).get("Health", [])))')

  echo "  DNS: ${DNS_NAME:-unknown}"
  if [ -z "$NODE_KEY" ]; then
    echo "  Node key missing. Skipping."
    continue
  fi

  if ! printf '%s' "$HEALTH" | grep -q 'locked out'; then
    echo "  Already signed or not locked out."
    continue
  fi

  echo "  Signing node key: $NODE_KEY"
  if "${SIGN_CMD[@]}" "$NODE_KEY"; then
    SIGNED=$((SIGNED + 1))
    echo "  Signed."
  else
    echo "  Signing failed. If access is denied, rerun: ./tailscale/sign-proxies.sh --sudo"
    NEEDS_SUDO=1
  fi
done

if [ "$NEEDS_SUDO" -ne 0 ]; then
  exit 1
fi

echo "Signed proxy nodes: $SIGNED"
