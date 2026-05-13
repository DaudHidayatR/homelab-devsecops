#!/usr/bin/env bash
set -euo pipefail

HOSTS=(
  "openbao-openbao.tailbec259.ts.net:/ui/"
  "kube-system-headlamp.tailbec259.ts.net:/"
  "messaging-rabbitmq.tailbec259.ts.net:/"
)

if [ "$#" -gt 0 ]; then
  HOSTS=("$@")
fi

FAILED=0

echo "=== Tailscale Kubernetes proxy pods ==="
kubectl get pods -n tailscale \
  -l tailscale.com/managed=true,tailscale.com/parent-resource-type=svc \
  -o wide || true

echo ""
echo "=== Tailscale Serve status ==="
mapfile -t PROXY_PODS < <(kubectl get pods -n tailscale \
  -l tailscale.com/managed=true,tailscale.com/parent-resource-type=svc \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
for pod in "${PROXY_PODS[@]}"; do
  echo "--- $pod ---"
  kubectl exec -n tailscale "$pod" -c tailscale -- tailscale serve status 2>/dev/null || true
done

echo ""
echo "=== DNS and HTTPS checks ==="
for item in "${HOSTS[@]}"; do
  host="${item%%:*}"
  path="${item#*:}"
  if [ "$host" = "$path" ]; then
    path="/"
  fi

  echo "--- $host ---"
  if getent hosts "$host"; then
    echo "  DNS OK"
  else
    echo "  DNS FAILED"
    FAILED=$((FAILED + 1))
    continue
  fi

  if curl -kI --max-time 15 "https://${host}${path}" >/tmp/tailscale-check.$$ 2>/tmp/tailscale-check.err.$$; then
    sed -n '1,8p' /tmp/tailscale-check.$$
    echo "  HTTPS OK"
  else
    echo "  HTTPS FAILED"
    sed -n '1,8p' /tmp/tailscale-check.err.$$ || true
    FAILED=$((FAILED + 1))
  fi
  rm -f /tmp/tailscale-check.$$ /tmp/tailscale-check.err.$$
done

if [ "$FAILED" -gt 0 ]; then
  echo "Checks failed: $FAILED"
  exit 1
fi

echo "All Tailscale access checks passed."
