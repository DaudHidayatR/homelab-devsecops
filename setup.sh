#!/usr/bin/env bash
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.env"

echo "=== 1. Creating kind cluster (rootless) ==="
if kind get clusters | awk -v name="${CLUSTER_NAME}" '$0 == name {found=1} END {exit !found}'; then
  echo "    Kind cluster \"${CLUSTER_NAME}\" already exists, skipping creation."
  kubectl config use-context "$CLUSTER_CONTEXT" >/dev/null 2>&1 || true
else
  kind create cluster --config kind/cluster.yaml
fi

echo "=== 2. Installing Istio ==="
istioctl install -f istio/istio-operator.yaml -y

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

echo "=== 4. Bootstrapping Flux CD ==="
if command -v flux >/dev/null 2>&1; then
  echo "    Flux CLI found. Running pre-flight checks..."
  if flux check --pre >/dev/null 2>&1; then
    if [ -n "${GITHUB_TOKEN:-}" ] && [ -n "${GITHUB_USER:-}" ]; then
      echo "    Bootstrapping Flux from GitHub..."
      flux bootstrap github \
        --owner="$GITHUB_USER" \
        --repository=project-ssdlc-devsecops-boilerplate \
        --branch=main \
        --path=./clusters/kind \
        --personal
      echo "    ✓ Flux bootstrapped. Cluster state is now managed by GitOps."
    else
      echo "    GITHUB_TOKEN or GITHUB_USER not set."
      echo "    Set these in config.env or your environment to enable GitOps."
      echo "    Falling back to kubectl apply -k..."
      kubectl apply -k "${SCRIPT_DIR}"
    fi
  else
    echo "    ⚠ Flux pre-flight checks failed."
    echo "    Falling back to kubectl apply -k..."
    kubectl apply -k "${SCRIPT_DIR}"
  fi
else
  echo "    Flux CLI not found. Install from https://fluxcd.io/flux/installation/"
  echo "    Falling back to kubectl apply -k..."
  kubectl apply -k "${SCRIPT_DIR}"
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
  if ! kubectl get deployment operator -n tailscale &>/dev/null; then
    echo "    Installing Tailscale Kubernetes Operator..."
    kubectl apply -f https://raw.githubusercontent.com/tailscale/tailscale/main/cmd/k8s-operator/deploy/manifests/operator.yaml
    echo "    Waiting for operator to be ready..."
    kubectl rollout status deployment/operator -n tailscale --timeout=120s
    echo "    ✓ Tailscale operator is ready."
  else
    echo "    Tailscale operator already installed."
  fi

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
