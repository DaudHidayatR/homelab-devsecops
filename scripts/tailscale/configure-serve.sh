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

  # Check current serve configuration. We still determine the desired backend
  # before deciding to skip, because multi-port services like RabbitMQ expose
  # AMQP first and the HTTP management UI second.
  SERVE_STATUS=$(kubectl exec -n tailscale "$POD" -c tailscale -- \
    tailscale serve status 2>/dev/null || true)

  echo "  Determining backend URL..."

  # Get TS_DEST_IP from the pod's environment
  # shellcheck disable=SC2016
  DEST_IP=$(kubectl exec -n tailscale "$POD" -c tailscale -- \
    sh -c 'echo $TS_DEST_IP' 2>/dev/null || true)

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
  BACKEND_TARGET=$(kubectl get svc -n "$PARENT_NS" "$PARENT_SVC" -o json 2>/dev/null | python3 -c "
import json, sys
svc = json.load(sys.stdin)
ports = svc.get('spec', {}).get('ports', [])
preferred_names = ('https', 'http', 'management', 'web', 'ui')

def scheme_for(port):
    name = str(port.get('name', '')).lower()
    app_protocol = str(port.get('appProtocol', '')).lower()
    if name == 'https' or app_protocol == 'https' or app_protocol == 'kubernetes.io/h2c':
        return 'https' if app_protocol != 'kubernetes.io/h2c' else 'http'
    if name == 'http' or app_protocol == 'http' or app_protocol == 'kubernetes.io/ws':
        return 'http'
    if 'https' in name or 'https' in app_protocol:
        return 'https'
    return 'http'

for wanted in preferred_names:
    for port in ports:
        if port.get('name') == wanted:
            print(scheme_for(port), port.get('port'))
            raise SystemExit
for port in ports:
    name = port.get('name', '')
    app_protocol = str(port.get('appProtocol', '')).lower()
    if 'http' in name or 'http' in app_protocol:
        print(scheme_for(port), port.get('port'))
        raise SystemExit
if ports:
    print(scheme_for(ports[0]), ports[0].get('port'))
" || true)

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
  RESULT=$(kubectl exec -n tailscale "$POD" -c tailscale -- \
    tailscale serve --bg --set-path / "$BACKEND_URL" 2>&1 || true)

  if echo "$RESULT" | grep -q "Success\|Available within your tailnet"; then
    echo "  ✓ Serve configured successfully."
    CONFIGURED=$((CONFIGURED + 1))
  else
    echo "  ✗ Failed to configure serve:"
    while IFS= read -r line; do echo "    $line"; done <<< "$RESULT"
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
