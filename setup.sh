#!/usr/bin/env bash
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.env"

echo "=== 1. Creating kind cluster (rootless) ==="
# Substitute TAILSCALE_VPS_HOSTNAME in certSANs if configured
if [ -n "${TAILSCALE_VPS_HOSTNAME:-}" ]; then
  echo "    Patching kind/cluster.yaml certSANs with ${TAILSCALE_VPS_HOSTNAME}..."
  sed -i "s/TAILSCALE_VPS_HOSTNAME_PLACEHOLDER/${TAILSCALE_VPS_HOSTNAME}/g" kind/cluster.yaml
fi
if kind get clusters | awk -v name="${CLUSTER_NAME}" '$0 == name {found=1} END {exit !found}'; then
  echo "    Kind cluster \"${CLUSTER_NAME}\" already exists, skipping creation."
  kubectl config use-context "$CLUSTER_CONTEXT" >/dev/null 2>&1 || true
else
  # Substitute certSANs placeholders with values from config.env
  CLUSTER_CONFIG=$(mktemp /tmp/kind-cluster.XXXXXX.yaml)
  cp "${SCRIPT_DIR}/kind/cluster.yaml" "$CLUSTER_CONFIG"
  if [ -n "${TAILSCALE_VPS_IP:-}" ]; then
    sed -i "s/TAILSCALE_VPS_IP_PLACEHOLDER/${TAILSCALE_VPS_IP}/g" "$CLUSTER_CONFIG"
  else
    sed -i '/TAILSCALE_VPS_IP_PLACEHOLDER/d' "$CLUSTER_CONFIG"
  fi
  if [ -n "${TAILSCALE_VPS_HOSTNAME:-}" ]; then
    sed -i "s/TAILSCALE_VPS_HOSTNAME_PLACEHOLDER/${TAILSCALE_VPS_HOSTNAME}/g" "$CLUSTER_CONFIG"
  else
    sed -i '/TAILSCALE_VPS_HOSTNAME_PLACEHOLDER/d' "$CLUSTER_CONFIG"
  fi
  kind create cluster --config "$CLUSTER_CONFIG"
  rm -f "$CLUSTER_CONFIG"
fi

echo "=== 2. Istio will be deployed via Flux HelmRelease (infrastructure/istio/)"

echo "=== 3. Deploying RabbitMQ credentials ==="
# The namespace is declarative in infrastructure/namespaces/, but the
# runtime-generated RabbitMQ secret must be created before Flux/app fallback
# reconciliation starts. Apply the namespace idempotently first so fresh
# clusters do not fail on a missing namespace.
kubectl apply -f "${SCRIPT_DIR}/infrastructure/namespaces/messaging.yaml"

# Generate RabbitMQ secret dynamically if it does not exist
# (secret files are no longer committed to Git)
if ! kubectl get secret rabbitmq-credentials -n "${RABBITMQ_NAMESPACE}" &>/dev/null; then
  echo "Generating RabbitMQ credentials secret..."
  RMQ_PASS=$(openssl rand -base64 32 | tr -d '\n')
  kubectl create secret generic rabbitmq-credentials \
    --namespace="${RABBITMQ_NAMESPACE}" \
    --from-literal=RABBITMQ_DEFAULT_USER=admin \
    --from-literal=RABBITMQ_DEFAULT_PASS="$RMQ_PASS"
fi

echo "=== 3.5. Generating OpenBao TLS certificate ==="
kubectl apply -f "${SCRIPT_DIR}/infrastructure/namespaces/openbao.yaml"
if ! kubectl get secret openbao-tls -n openbao &>/dev/null; then
  echo "    Generating self-signed TLS cert for OpenBao..."
  openssl req -x509 -nodes -newkey rsa:2048 \
    -keyout /tmp/openbao-tls.key -out /tmp/openbao-tls.crt \
    -days 3650 -subj "/CN=openbao.openbao.svc.cluster.local" \
    -addext "subjectAltName=DNS:openbao.openbao.svc.cluster.local,DNS:openbao.openbao.svc,DNS:openbao,DNS:localhost,IP:127.0.0.1" 2>/dev/null
  kubectl create secret tls openbao-tls \
    --namespace=openbao \
    --cert=/tmp/openbao-tls.crt \
    --key=/tmp/openbao-tls.key
  rm -f /tmp/openbao-tls.crt /tmp/openbao-tls.key
  echo "    ✓ OpenBao TLS secret created."
else
  echo "    OpenBao TLS secret already exists, skipping."
fi

echo "=== 4. Bootstrapping Flux CD ==="
if command -v flux >/dev/null 2>&1; then
  echo "    Flux CLI found. Running pre-flight checks..."
  if flux check --pre >/dev/null 2>&1; then
    if [ -n "${GITHUB_TOKEN:-}" ] && [ -n "${GITHUB_USER:-}" ]; then
      echo "    Bootstrapping Flux from GitHub..."
      flux bootstrap github \
        --owner="$GITHUB_USER" \
        --repository=homelab-devsecops \
        --branch=main \
        --path=./clusters/kind \
        --personal
      echo "    ✓ Flux bootstrapped. Cluster state is now managed by GitOps."
    else
      echo "    GITHUB_TOKEN or GITHUB_USER not set."
      echo "    Set these in config.env or your environment to enable GitOps."
      echo "    Falling back to kubectl apply -k..."
      kubectl apply -k "${SCRIPT_DIR}/infrastructure"
      kubectl apply -k "${SCRIPT_DIR}/apps"
    fi
  else
    echo "    ⚠ Flux pre-flight checks failed."
    echo "    Falling back to kubectl apply -k..."
    kubectl apply -k "${SCRIPT_DIR}/infrastructure"
    kubectl apply -k "${SCRIPT_DIR}/apps"
  fi
else
  echo "    Flux CLI not found. Install from https://fluxcd.io/flux/installation/"
  echo "    Falling back to kubectl apply -k..."
  kubectl apply -k "${SCRIPT_DIR}/infrastructure"
  kubectl apply -k "${SCRIPT_DIR}/apps"
fi

echo "=== 4.5. Configuring Tailscale annotations on OpenBao ==="
# The OpenBao Helm chart creates 5+ services, but we only want the main
# 'openbao' Service exposed. Annotating server.service.annotations in
# values.yaml would apply to ALL services, causing duplicate Tailscale proxy
# pods. Instead, annotate only the main Service here.
if kubectl get svc openbao -n openbao &>/dev/null; then
  kubectl annotate svc openbao -n openbao \
    tailscale.com/expose=true \
    tailscale.com/serve=true \
    --overwrite
  echo "    ✓ OpenBao main Service annotated for Tailscale."
else
  echo "    ⚠ openbao Service not found — skipping annotation."
fi

echo "=== 5. Installing Tailscale Operator (optional) ==="
if [ -n "${TAILSCALE_CLIENT_ID}" ] && [ -n "${TAILSCALE_CLIENT_SECRET}" ]; then
  if ! kubectl get namespace tailscale &>/dev/null; then
    kubectl create namespace tailscale --dry-run=client -o yaml | kubectl apply -f -
  fi
  if ! kubectl get secret operator-oauth -n tailscale &>/dev/null; then
    echo "    Creating Tailscale OAuth secret..."
    kubectl create secret generic operator-oauth \
      --namespace tailscale \
      --from-literal=client_id="${TAILSCALE_CLIENT_ID}" \
      --from-literal=client_secret="${TAILSCALE_CLIENT_SECRET}"
  fi

  # Preserve operator machine identity across reinstalls.
  # The k8s-operator stores its device identity (_machinekey, profile-*)
  # in the Secret named by OPERATOR_SECRET (default: "operator"). If this
  # Secret is lost (e.g. accidental deletion, namespace recreation) the
  # operator re-registers with Tailscale using the same hostname, creating
  # a duplicate device entry (tailscale-operator-1, -2, ...).
  IDENTITY_BACKUP=$(mktemp)
  if kubectl get secret operator -n tailscale &>/dev/null; then
    kubectl get secret operator -n tailscale -o json >"$IDENTITY_BACKUP"
    echo "    Backed up existing operator identity."
  fi

  if ! kubectl get deployment operator -n tailscale &>/dev/null; then
    echo "    Installing Tailscale Kubernetes Operator..."
    kubectl apply -f https://raw.githubusercontent.com/tailscale/tailscale/v1.96.4/cmd/k8s-operator/deploy/manifests/operator.yaml
    echo "    Waiting for operator to be ready..."
    kubectl rollout status deployment/operator -n tailscale --timeout=120s
    echo "    ✓ Tailscale operator is ready."
  else
    echo "    Tailscale operator already installed."
  fi

  # Restore operator identity if the Secret was wiped by the install manifest.
  # This prevents duplicate device registrations in the Tailscale admin console.
  if [ -s "$IDENTITY_BACKUP" ]; then
    IDENTITY_KEYS=$(python3 -c "
import json, sys
with open('$IDENTITY_BACKUP') as f:
    d = json.load(f)
keys = [k for k in d.get('data',{}) if k.startswith('_machinekey') or k.startswith('_current-profile') or k.startswith('profile-')]
print(' '.join(keys))" 2>/dev/null || true)
    if [ -n "$IDENTITY_KEYS" ]; then
      echo "    Restoring operator device identity to prevent duplicate..."
      kubectl get secret operator -n tailscale -o json 2>/dev/null | python3 -c "
import json, sys
# Merge identity keys from backup into live secret
backup = json.load(open('$IDENTITY_BACKUP'))
live = json.load(sys.stdin)
for k, v in backup.get('data', {}).items():
    if k.startswith('_machinekey') or k.startswith('_current-profile') or k.startswith('profile-'):
        live.setdefault('data', {})[k] = v
json.dump(live, sys.stdout)" | kubectl replace -f - 2>/dev/null || true
      echo "    ✓ Operator identity preserved."
    fi
  fi
  rm -f "$IDENTITY_BACKUP"

  # Wait for proxy pods to be created by the operator
  echo "    Waiting for Tailscale proxy pods to be ready..."
  for _i in $(seq 1 30); do
    PROXY_COUNT=$(kubectl get pods -n tailscale -l tailscale.com/managed=true,tailscale.com/parent-resource-type=svc --no-headers 2>/dev/null | grep -cv 'operator-' || true)
    if [ "$PROXY_COUNT" -gt 0 ]; then
      echo "    ✓ Found $PROXY_COUNT proxy pod(s)."
      break
    fi
    sleep 5
  done

  # Configure tailscale serve on all proxy pods
  echo "    Configuring tailscale serve on proxy pods..."
  "${SCRIPT_DIR}/scripts/configure-tailscale-serve.sh"

  # Deploy serve-watcher for persistence across proxy restarts
  echo "    Deploying tailscale serve watcher (keeps serve config persistent)..."
  kubectl apply -f "${SCRIPT_DIR}/tailscale/serve-watcher.yaml"
  echo "    ✓ Serve watcher deployed."
else
  echo "    TAILSCALE_CLIENT_ID or TAILSCALE_CLIENT_SECRET not set."
  echo "    Skipping Tailscale operator. Set credentials in config.env to enable."
fi

# SRP: access instructions live in their own script; setup.sh ends at infrastructure readiness.
"${SCRIPT_DIR}/scripts/show-access-info.sh"
