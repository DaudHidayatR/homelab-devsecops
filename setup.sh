#!/usr/bin/env bash
set -eo pipefail

CLUSTER_NAME="rootless-mesh"
CLUSTER_CONTEXT="kind-${CLUSTER_NAME}"
OPENBAO_NAMESPACE="openbao"
OPENBAO_RELEASE="openbao"
OPENBAO_CHART_VERSION="0.26.2"
OPENBAO_IMAGE="quay.io/openbao/openbao:2.5.2"


echo "=== 1. Creating kind cluster (rootless) ==="
if kind get clusters | awk '$0 == "rootless-mesh" {found=1} END {exit !found}'; then
  echo "    Kind cluster \"${CLUSTER_NAME}\" already exists, skipping creation."
  kubectl config use-context "$CLUSTER_CONTEXT" >/dev/null 2>&1 || true
else
  kind create cluster --config kind/cluster.yaml
fi

echo "=== 2. Installing Istio ==="
istioctl install -f istio/istio-operator.yaml -y

echo "=== 3. Applying demo namespace ==="
kubectl apply -f apps/demo/namespace.yaml

echo "=== 3.5. Deploying RabbitMQ ==="
kubectl apply -f rabbitmq/

echo "=== 4. Deploying sample application ==="
kubectl apply -f apps/demo/sample-app/deployment.yaml

echo "=== 5. Installing Headlamp Web UI ==="
kubectl apply -f headlamp/headlamp.yaml

echo "=== 6. Configuring Headlamp access ==="
kubectl apply -f headlamp/headlamp-admin.yaml

echo "=== 7. Deploying OpenBao (secret management — raft storage) ==="

kubectl apply -f openbao/namespace.yaml

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
echo "To access Headlamp Web UI:"
echo "1. Run: kubectl port-forward -n kube-system service/headlamp 8080:80"
echo "2. Get your login token: kubectl create token headlamp-admin -n kube-system"
echo "3. Open http://localhost:8080 in your browser"
echo ""
echo "To access RabbitMQ Management UI:"
echo "1. Run: kubectl port-forward -n messaging svc/rabbitmq 15672:15672"
echo "2. Open http://localhost:15672 (admin / password123)"
echo ""
echo "To bootstrap OpenBao (raft integrated storage):"
echo "1. Run: kubectl port-forward -n openbao svc/openbao 8200:8200"
echo "2. Initialize once: kubectl exec -it -n openbao openbao-0 -- bao operator init -key-shares=1 -key-threshold=1"
echo "3. Unseal with the returned key: kubectl exec -it -n openbao openbao-0 -- bao operator unseal <unseal_key>"
echo "4. Open http://localhost:8200 in your browser"
echo "5. Back up the init output outside the cluster (root token + unseal key)"
echo "6. Verify raft: kubectl exec -n openbao openbao-0 -- bao operator raft list-peers"
