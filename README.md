# Minimal Rootless Kubernetes & Istio Lab

A minimal, rootless local development environment using `kind`, Istio, and RabbitMQ. Designed for learning service mesh basics and asynchronous messaging without heavy resource overhead.

## Prerequisites
- Linux OS
- Rootless Docker *(Note: Podman can also be used by setting `KIND_EXPERIMENTAL_PROVIDER=podman`)*
- `kind` CLI
- `kubectl` CLI *(Kustomize is built-in since v1.14; no separate install needed)*
- `istioctl` CLI
- `helm` CLI

## Project Structure
The configuration is modularized into logical directories:
- `kind/`: Cluster bootstrapping configurations.
- `istio/`: Declarative `istiod` control plane configuration.
- `rabbitmq/`: RabbitMQ message broker manifests in a dedicated namespace (kept outside the mesh).
- `headlamp/`: Kubernetes Web UI manifests for visual management.
- `openbao/`: OpenBao secret-management manifests and Helm values — single-node raft (kept outside the mesh).
- `apps/`: Application deployments structured by `namespace/service`.
- `bases/`: Reusable Kustomize bases for shared security contexts, network policies, and namespace labels.
- `config.env`: Centralized constants (cluster name, namespaces, image versions) shared by scripts and manifests.

## Usage
1. Make the scripts executable:
   ```bash
   chmod +x setup.sh destroy.sh
   ```
2. Customize `config.env` if you want to change cluster names, namespaces, or image versions.
3. Run the automated setup:
   ```bash
   ./setup.sh
   ```

Components are deployed via `kubectl apply -k` using Kustomize overlays. Each component directory (`apps/demo/`, `rabbitmq/`, `headlamp/`, `openbao/`) contains a `kustomization.yaml` that composes shared bases with component-specific resources.

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
OpenBao is deployed to the `openbao` namespace via the official Helm chart using **single-node raft** storage.

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
4. Open [http://localhost:8200](http://localhost:8200) in your browser.

### Important Notes
- **Back up the init output**: Store the root token and unseal key outside the cluster. Losing them means rebuilding the lab and recreating secrets.
- **Data Persistence**: OpenBao uses raft storage backed by a PVC. Data survives pod restarts but is lost when the kind cluster is destroyed.
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

## Security Scanning Strategy

The project uses a **dual-scan approach** to balance early feedback with authoritative validation:

### 1. Raw-File Scanning (`trivy fs`)
- Scans source files directly for vulnerabilities, secrets, and misconfigurations
- Provides immediate feedback on uncommitted changes
- May report false positives for Kubernetes manifests because Kustomize patches are applied at build time

### 2. Rendered-Manifest Scanning (`kustomize build | trivy config`)
- Compiles Kustomize overlays and patches into the final Kubernetes manifests
- Scans the **actual state** that `kubectl apply -k` sends to the API server
- Eliminates false positives from Kustomize-injected `securityContext` patches
- Serves as the **authoritative security gate** before deployment

### Running Scans Locally
```bash
./test-security-app.sh
```

This script generates:
- `trivy-report.*` — raw filesystem scan (vulnerabilities, secrets, misconfigs)
- `trivy-rendered.sarif` — rendered manifest scan (authoritative K8s policy check)
- `semgrep-report.*` — static analysis findings
- `gitleaks-report.json` — secret detection
- `grype-report.json` — alternative vulnerability scan
- `sbom-*.json` — software bill of materials (SPDX + CycloneDX)

All report artifacts are excluded from Git via `.gitignore`.

### Scanner Versions
All scanner images are pinned to specific versions for reproducible results. Override via environment variables if needed:
```bash
TRIVY_IMAGE=ghcr.io/aquasecurity/trivy:0.70.0 ./test-security-app.sh
```

### Known False Positives
Both Trivy (`trivy-report.sarif`) and Semgrep (`semgrep-report.sarif`) may report Kubernetes security findings (missing `securityContext`, `runAsNonRoot`, etc.) in raw YAML files. These are **expected false positives** because Kustomize patches inject the hardening at build time. The authoritative validation is always the **rendered manifest scan** (`trivy-rendered.sarif`), which evaluates the actual state sent to the Kubernetes API server.

We intentionally keep the K8s rules active in both Trivy and Semgrep as a safety net: if a Deployment is accidentally removed from `kustomization.yaml` patches, the raw-file scan will immediately flag the unhardened manifest.
