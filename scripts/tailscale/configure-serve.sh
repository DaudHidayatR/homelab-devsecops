#!/usr/bin/env bash
set -eo pipefail

# configure-tailscale-serve.sh — Configures 'tailscale serve' on all Tailscale
# Kubernetes Operator proxy pods. The operator (as of v1.96) does not always
# configure serve automatically, causing HTTPS connections to fail with
# ERR_CONNECTION_TIMED_OUT from tailnet clients.
#
# This script is idempotent — safe to run multiple times.
# It should be run after initial setup and any time proxy pods restart.

echo "=== Configuring tailscale serve on proxy pods ==="

# Find all proxy pods managed by the tailscale operator
PROXY_PODS=$(kubectl get pods -n tailscale \
  -l tailscale.com/managed=true,tailscale.com/parent-resource-type=svc \
  -o json 2>/dev/null | python3 -c "
import sys, json
pods = json.load(sys.stdin).get('items', [])
for pod in pods:
    name = pod['metadata']['name']
    # Skip operator pod
    if name.startswith('operator-'):
        continue
    print(name)
" 2>/dev/null)

if [ -z "$PROXY_PODS" ]; then
  echo "No Tailscale proxy pods found. Nothing to configure."
  exit 0
fi

echo "Found proxy pods:"
echo "$PROXY_PODS" | while read -r pod; do echo "  - $pod"; done

CONFIGURED=0
SKIPPED=0
FAILED=0

for POD in $PROXY_PODS; do
  echo ""
  echo "--- Checking $POD ---"

  # Read current Serve configuration before deciding whether an update is needed.
  if ! SERVE_STATUS=$(kubectl exec -n tailscale "$POD" -c tailscale -- tailscale serve status 2>/dev/null); then
    SERVE_STATUS=""
  fi

  echo "  Determining backend URL..."

  DEST_IP=$(kubectl get pod -n tailscale "$POD" -o json | python3 -c "import json,sys; d=json.load(sys.stdin); print(next((e.get('value','') for c in d['spec'].get('containers',[]) if c.get('name')=='tailscale' for e in c.get('env',[]) if e.get('name')=='TS_DEST_IP'),''))")

  if [ -z "$DEST_IP" ]; then
    echo "  ✗ Could not determine TS_DEST_IP for $POD. Skipping."
    FAILED=$((FAILED + 1))
    continue
  fi

  # Get the parent service name and namespace
  PARENT_SVC=$(kubectl get pod -n tailscale "$POD" \
    -o jsonpath='{.metadata.labels.tailscale\.com/parent-resource}' 2>/dev/null || true)
  PARENT_NS=$(kubectl get pod -n tailscale "$POD" \
    -o jsonpath='{.metadata.labels.tailscale\.com/parent-resource-ns}' 2>/dev/null || true)

  if [ -z "$PARENT_SVC" ] || [ -z "$PARENT_NS" ]; then
    echo "  ✗ Could not determine parent service for $POD. Skipping."
    FAILED=$((FAILED + 1))
    continue
  fi

  # Pick an HTTP-compatible service port for Tailscale Serve.
  # Prefer explicit web/management ports before falling back to the first port.
  # Return both scheme and port so HTTPS-only backends like OpenBao are not
  # incorrectly contacted over plaintext HTTP.
  if ! BACKEND_TARGET=$(kubectl get svc -n "$PARENT_NS" "$PARENT_SVC" -o json | python3 -c "
import json, sys
ports = json.load(sys.stdin).get('spec', {}).get('ports', [])
def classify(p):
    name = str(p.get('name', '')).lower()
    proto = str(p.get('appProtocol', '')).lower()
    if proto in ('https', 'kubernetes.io/https') or name == 'https' or 'https' in name:
        return 'https'
    if proto in ('http', 'kubernetes.io/http', 'kubernetes.io/ws', 'kubernetes.io/h2c') or name in ('http','web','ui','management') or name.startswith('http-'):
        return 'http'
    return None
explicit = [(classify(p), p.get('port')) for p in ports if classify(p)]
if len(explicit) == 1:
    print(*explicit[0])
elif len(explicit) > 1:
    raise SystemExit('ambiguous HTTP service ports')
elif len(ports) == 1:
    raise SystemExit('single service port lacks explicit HTTP semantics')
else:
    raise SystemExit('no unambiguous HTTP service port')
"); then
    echo "  ✗ Service $PARENT_NS/$PARENT_SVC has no unambiguous HTTP backend."
    FAILED=$((FAILED + 1))
    continue
  fi

  BACKEND_SCHEME=${BACKEND_TARGET%% *}
  TARGET_PORT=${BACKEND_TARGET##* }

  if [ -z "$TARGET_PORT" ]; then
    echo "  ✗ Could not determine target port for $PARENT_SVC in $PARENT_NS. Skipping."
    FAILED=$((FAILED + 1))
    continue
  fi

  BACKEND_URL="${BACKEND_SCHEME}://${DEST_IP}:${TARGET_PORT}"
  echo "  Backend: $BACKEND_URL"

  if echo "$SERVE_STATUS" | grep -q "$BACKEND_URL"; then
    echo "  ✓ Already configured:"
    while IFS= read -r line; do echo "    $line"; done <<< "$SERVE_STATUS"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  if echo "$SERVE_STATUS" | grep -q "https://"; then
    echo "  Existing serve config differs; updating:"
    while IFS= read -r line; do echo "    $line"; done <<< "$SERVE_STATUS"
  fi

  # Configure tailscale serve
  echo "  Configuring tailscale serve..."
  if ! RESULT=$(kubectl exec -n tailscale "$POD" -c tailscale -- \
    tailscale serve --bg --set-path / "$BACKEND_URL" 2>&1); then
    echo "  ✗ Failed to configure serve:"
    while IFS= read -r line; do echo "    $line"; done <<< "$RESULT"
    FAILED=$((FAILED + 1))
    continue
  fi
  if SERVE_STATUS=$(kubectl exec -n tailscale "$POD" -c tailscale -- tailscale serve status 2>/dev/null) && awk -v target="$BACKEND_URL" '{for (i=1;i<=NF;i++) if ($i == target) found=1} END {exit !found}' <<< "$SERVE_STATUS"; then
    echo "  ✓ Serve configured successfully."
    CONFIGURED=$((CONFIGURED + 1))
  else
    echo "  ✗ Serve status does not contain exact backend: $BACKEND_URL"
    FAILED=$((FAILED + 1))
  fi
done

echo ""
echo "=== Summary ==="
echo "  Configured: $CONFIGURED"
echo "  Skipped (already configured): $SKIPPED"
echo "  Failed: $FAILED"

if [ $FAILED -gt 0 ]; then
  exit 1
fi
