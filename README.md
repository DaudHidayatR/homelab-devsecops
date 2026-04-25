# Minimal Rootless Kubernetes & Istio Lab

A minimal, rootless local development environment using `kind`, Istio, and RabbitMQ. Designed for learning service mesh basics and asynchronous messaging without heavy resource overhead.

## Prerequisites
- Linux OS
- Rootless Docker *(Note: Podman can also be used by setting `KIND_EXPERIMENTAL_PROVIDER=podman`)*
- `kind` CLI
- `kubectl` CLI
- `istioctl` CLI
- `helm` CLI

## Project Structure
The configuration is modularized into logical directories:
- `kind/`: Cluster bootstrapping configurations.
- `istio/`: Declarative `istiod` control plane configuration.
- `rabbitmq/`: RabbitMQ message broker manifests in a dedicated namespace (kept outside the mesh).
- `headlamp/`: Kubernetes Web UI manifests for visual management.
- `openbao/`: OpenBao secret-management manifests and Helm values — raft integrated storage (kept outside the mesh).
- `apps/`: Application deployments structured by `namespace/service`.

## Usage
1. Make the scripts executable:
   ```bash
   chmod +x setup.sh destroy.sh
   ```
2. Run the automated setup:
   ```bash
   ./setup.sh
   ```

## Accessing Headlamp (Kubernetes Web UI)
This setup includes Headlamp to manage your cluster visually.

1. Port-forward the Headlamp service:
   ```bash
   kubectl port-forward -n kube-system service/headlamp 8080:80
   ```
2. In a new terminal, generate a login token:
   ```bash
   kubectl create token headlamp-admin -n kube-system
   ```
3. Open [http://localhost:8080](http://localhost:8080) in your browser and paste the token to log in.

## Accessing RabbitMQ
RabbitMQ is deployed to the `messaging` namespace.

1. Port-forward the RabbitMQ Management UI:
   ```bash
   kubectl port-forward -n messaging svc/rabbitmq 15672:15672
   ```
2. Open [http://localhost:15672](http://localhost:15672) in your browser.
3. Log in with credentials retrieved from the cluster secret:
   ```bash
   kubectl get secret rabbitmq-credentials -n messaging -o jsonpath='{.data.RABBITMQ_DEFAULT_PASS}' | base64 -d
   ```

### Inter-Service Communication
Your microservices can connect to RabbitMQ using the internal cluster DNS. Retrieve the password from the Kubernetes secret or OpenBao:
```
RABBITMQ_URL=amqp://admin:<password>@rabbitmq.messaging.svc.cluster.local:5672
```

## Accessing OpenBao (Secret Management)
OpenBao is deployed to the `openbao` namespace via the official Helm chart using **raft integrated storage** (single-node).

1. Port-forward the OpenBao service:
   ```bash
   kubectl port-forward -n openbao svc/openbao 8200:8200
   ```
2. Initialize OpenBao once:
   ```bash
   kubectl exec -it -n openbao openbao-0 -- bao operator init -key-shares=1 -key-threshold=1
   ```
3. Unseal OpenBao with the returned key:
   ```bash
   kubectl exec -it -n openbao openbao-0 -- bao operator unseal <unseal_key>
   ```
4. Verify raft storage:
   ```bash
   kubectl exec -n openbao openbao-0 -- bao operator raft list-peers
   ```
5. Open [http://localhost:8200](http://localhost:8200) in your browser.

### Important Notes
- **Back up the init output**: Store the root token and unseal key outside the cluster. Losing them means rebuilding the lab and recreating secrets.
- **Data Persistence**: OpenBao uses raft integrated storage backed by a PVC. Data survives pod restarts but is lost when the kind cluster is destroyed.
- **Raft Snapshots**: After unsealing, you can create backups with `bao operator raft snapshot save <path>`.
- **No ingress in phase 1**: Access is intentionally limited to `kubectl port-forward` for a smaller, easier-to-audit setup.

### Optional phase-1 bootstrap
After unsealing, you can enable the minimum useful features from inside the pod:

```bash
kubectl exec -it -n openbao openbao-0 -- sh
export BAO_ADDR=http://127.0.0.1:8200
bao login <root_token>
bao secrets enable -path=secret kv-v2
bao auth enable kubernetes
bao write auth/kubernetes/config kubernetes_host="https://$KUBERNETES_SERVICE_HOST:$KUBERNETES_SERVICE_PORT"
```

### Internal Access
Applications in the cluster can reach OpenBao at:
```
OPENBAO_ADDR=http://openbao.openbao.svc.cluster.local:8200
```

## Tear Down
To destroy the local infrastructure and free up resources, run the destroy script:
```bash
./destroy.sh
```
