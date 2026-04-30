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

echo "=== 3. Creating namespaces ==="
kubectl create namespace "${DEMO_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace "${RABBITMQ_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace "${OPENBAO_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

echo "=== 4. Deploying RabbitMQ credentials ==="

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

echo "=== 5. Applying all Kubernetes manifests ==="
kubectl apply -k "${SCRIPT_DIR}"

echo "=== 6. Deploying OpenBao (secret management — single-node raft) ==="

helm repo add openbao https://openbao.github.io/openbao-helm 2>/dev/null || true
helm repo update

echo "    Installing OpenBao via Helm..."
helm upgrade --install "$OPENBAO_RELEASE" \
  openbao/openbao \
  --namespace "$OPENBAO_NAMESPACE" \
  --version "$OPENBAO_CHART_VERSION" \
  --values openbao/values.yaml \
  --timeout 10m

CURRENT_OPENBAO_IMAGE=$(kubectl get pod -n "$OPENBAO_NAMESPACE" "${OPENBAO_RELEASE}-0" -o jsonpath='{.spec.containers[?(@.name=="openbao")].image}' 2>/dev/null || true)
if [ -n "$CURRENT_OPENBAO_IMAGE" ] && [ "$CURRENT_OPENBAO_IMAGE" != "$OPENBAO_IMAGE" ]; then
  echo "    Detected outdated OpenBao pod image (${CURRENT_OPENBAO_IMAGE}); recreating pod..."
  kubectl delete pod -n "$OPENBAO_NAMESPACE" "${OPENBAO_RELEASE}-0" --wait=false >/dev/null 2>&1 || true
fi

echo "    Waiting for OpenBao pod to report ready..."
if kubectl wait \
  --namespace "$OPENBAO_NAMESPACE" \
  --for=condition=Ready pod \
  -l app.kubernetes.io/name=openbao \
  --timeout=300s; then
  echo "    ✓ OpenBao pod is ready for bootstrap."
else
  echo "    ⚠  Timeout waiting for OpenBao readiness."
  echo "    Current pod status:"
  kubectl get pods -n "$OPENBAO_NAMESPACE" -o wide || true
  echo ""
  echo "    Check logs with:"
  echo "    kubectl describe pods -n ${OPENBAO_NAMESPACE}"
  echo "    kubectl logs -n ${OPENBAO_NAMESPACE} statefulset/${OPENBAO_RELEASE}"
  echo ""
  echo "    You can continue using the cluster. OpenBao may still be starting up."
fi

echo "=== Setup Complete! ==="
echo "Check pod status with: kubectl get pods -n demo"
echo ""
echo "--- Tailscale Private Access (recommended) ---"
echo "1. Install the Tailscale operator: ./tailscale/install-operator.sh"
echo "2. Once the operator is running, admin UIs are available on your tailnet:"
echo "   Headlamp:  https://headlamp-kube-system.<tailnet>.ts.net"
echo "   RabbitMQ:  https://rabbitmq-messaging.<tailnet>.ts.net"
echo "   OpenBao:   https://openbao-openbao.<tailnet>.ts.net"
echo ""
echo "--- Legacy Port-Forward Access ---"
echo "To access Headlamp Web UI:"
echo "1. Run: kubectl port-forward -n kube-system service/headlamp 8080:80"
echo "2. Get your login token: kubectl create token headlamp-admin -n kube-system"
echo "3. Open http://localhost:8080 in your browser"
echo ""
echo "To access RabbitMQ Management UI:"
echo "1. Run: kubectl port-forward -n messaging svc/rabbitmq 15672:15672"
echo "2. Open http://localhost:15672"
echo "3. Get the password: kubectl get secret rabbitmq-credentials -n messaging -o jsonpath='{.data.RABBITMQ_DEFAULT_PASS}' | base64 -d"
echo ""
echo "To bootstrap OpenBao (single-node raft):"
echo "1. Run: kubectl port-forward -n openbao svc/openbao 8200:8200"
echo "2. Initialize once: kubectl exec -it -n openbao openbao-0 -- bao operator init -key-shares=1 -key-threshold=1"
echo "3. Unseal with the returned key: kubectl exec -it -n openbao openbao-0 -- bao operator unseal <unseal_key>"
echo "4. Open http://localhost:8200 in your browser"
echo "5. Back up the init output outside the cluster (root token + unseal key)"
