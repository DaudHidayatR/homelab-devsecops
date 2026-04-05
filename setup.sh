#!/usr/bin/env bash
set -eo pipefail

echo "=== 1. Creating kind cluster (rootless) ==="
kind create cluster --config kind/cluster.yaml

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

echo "=== Setup Complete! ==="
echo "Check pod status with: kubectl get pods -n demo"
echo ""
echo "To access Headlamp Web UI:"
echo "1. Run: kubectl port-forward -n kube-system service/headlamp 8080:80"
echo "2. Get your login token: kubectl create token headlamp-admin -n kube-system"
echo "3. Open http://localhost:8080 in your browser"
