# Minimal Rootless Kubernetes & Istio Lab

A minimal, rootless local development environment using `kind`, Istio, and RabbitMQ. Designed for learning service mesh basics and asynchronous messaging without heavy resource overhead.

## Prerequisites
- Linux OS
- Rootless Docker *(Note: Podman can also be used by setting `KIND_EXPERIMENTAL_PROVIDER=podman`)*
- `kind` CLI
- `kubectl` CLI *(Kustomize is built-in since v1.14; no separate install needed)*
- `istioctl` CLI
- `helm` CLI *(fallback only; Flux manages OpenBao declaratively)*
- `flux` CLI *(optional; enables GitOps reconciliation. Install from [fluxcd.io](https://fluxcd.io/flux/installation/))*

## Project Structure
The configuration is modularized into logical directories:
- `clusters/kind/`: Flux CD GitOps entry point — `Kustomization` CRDs that reconcile `infrastructure/` and `apps/`.
- `infrastructure/`: Foundational cluster resources — namespaces and declarative Helm releases (OpenBao).
- `kind/`: Cluster bootstrapping configurations.
- `istio/`: Declarative `istiod` control plane configuration.
- `apps/`: Flux-managed application and access-layer overlays. It aggregates `apps/demo/`, `apps/rabbitmq/`, `apps/headlamp/`, and `apps/openbao/` through `apps/kustomization.yaml`.
- `apps/rabbitmq/`: RabbitMQ message broker manifests in a dedicated namespace (kept outside the mesh).
- `apps/headlamp/`: Kubernetes Web UI manifests for visual management.
- `apps/openbao/`: OpenBao NetworkPolicies for application/admin access — the actual OpenBao Helm deployment is managed by Flux via `infrastructure/openbao/`.
- `bases/`: Reusable Kustomize bases for shared security contexts, network policies, and namespace labels.
- `config.env`: Centralized constants (cluster name, namespaces, image versions) shared by scripts and manifests.

## Usage
1. Make the scripts executable:
   ```bash
   chmod +x setup.sh destroy.sh
   ```
2. Customize `config.env` if you want to change cluster names, namespaces, or image versions.
3. Deploy the lab with Make:
   ```bash
   make up
   ```
   Or run the setup script directly:
   ```bash
   ./setup.sh
   ```

Common workflows:
| Command | Action |
|---------|--------|
| `make up` | Deploy the full cluster and all components |
| `make down` | Tear down the kind cluster |
| `make scan` | Run the security scanner suite |
| `make tailscale` | Install the Tailscale Kubernetes Operator |
| `make status` | Show pod status across all namespaces |
| `make validate-kustomize` | Validate all Kustomize overlays |
| `make sync` | Trigger immediate Flux reconciliation |
| `make flux-status` | Show Flux resource status |
| `make flux-diff` | Show pending changes for Flux-managed resources |

Components are deployed via **Flux CD** when `GITHUB_TOKEN` and `GITHUB_USER` are configured. Flux continuously reconciles `infrastructure/` first, then `apps/` after infrastructure is ready. If Flux is not available, `setup.sh` falls back to the root `kubectl apply -k` aggregate, which includes the same infrastructure and app layers for local use.

## Versioning

All component versions are centralized in `config.env` and injected into manifests via Kustomize `images` patches. To upgrade a component, edit only `config.env` and the corresponding `images.newTag` in the component's `kustomization.yaml`.

| Component | Version Source | Kustomize Patch |
|-----------|---------------|-----------------|
| OpenBao | `config.env: OPENBAO_VERSION` | `infrastructure/openbao/values.yaml` (Flux Helm values) |
| Headlamp | `config.env: HEADLAMP_VERSION` | `apps/headlamp/kustomization.yaml` |
| RabbitMQ | `config.env: RABBITMQ_VERSION` | `apps/rabbitmq/kustomization.yaml` |
| Sample App | `config.env: SAMPLE_APP_VERSION` | `apps/demo/kustomization.yaml` |

Tag the repository after each validated deployment:
```bash
git tag -a infra-v1.0 -m "Baseline deployment"
git push origin infra-v1.0
```

## GitOps with Flux CD

This project uses [Flux CD](https://fluxcd.io) to automatically reconcile cluster state with this Git repository.

### Enabling Flux

1. Install the Flux CLI: https://fluxcd.io/flux/installation/
2. Add your GitHub credentials to `config.env`:
   ```bash
   GITHUB_USER="your-github-username"
   GITHUB_TOKEN="ghp_xxxxxxxxxxxx"
   ```
3. Run `make up` — `setup.sh` will bootstrap Flux after creating the cluster.

### How Flux Works Here

| Flux Resource | Purpose |
|-------------|---------|
| `clusters/kind/infrastructure.yaml` | Reconciles namespaces and the OpenBao HelmRelease layer |
| `clusters/kind/apps.yaml` | Reconciles the buildable `apps/` aggregate: demo app, RabbitMQ, Headlamp, and OpenBao NetworkPolicies |
| `infrastructure/openbao/helmrepository.yaml` | Indexes the OpenBao Helm chart repository |
| `infrastructure/openbao/helmrelease.yaml` | Declaratively installs/upgrades OpenBao |

### Daily Operations

```bash
# Trigger immediate reconciliation
make sync

# Check Flux resource status
make flux-status

# Preview what would change
make flux-diff

# Watch reconciliation in real-time
flux get kustomizations --watch

# View Flux logs for errors
flux logs --level=error
```

### Drift Detection

If you manually edit a resource (e.g., `kubectl edit deployment`), Flux will automatically revert the change on its next reconciliation interval (default: 30 minutes). Run `make sync` to force immediate reconciliation.

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

## Tailscale Private Access (Recommended)

Admin services are annotated for automatic tailnet exposure via the Tailscale Kubernetes Operator.

1. Install the operator:
   ```bash
   ./tailscale/install-operator.sh
   ```
   (Requires a Tailscale OAuth client; see `tailscale/README.md` for setup.)

2. Once the operator is running, access admin UIs directly from any device on your tailnet:

   | Service | Tailnet URL |
   |---------|-------------|
   | Headlamp | `https://headlamp-kube-system.<tailnet>.ts.net` |
   | RabbitMQ | `https://rabbitmq-messaging.<tailnet>.ts.net` |
   | OpenBao  | `https://openbao-openbao.<tailnet>.ts.net` |

3. No port-forwarding, SSH tunnels, or public IPs required.

### Future Public Access

To expose a service to the public internet, change the annotation from:
```yaml
tailscale.com/expose: "true"
```
to:
```yaml
tailscale.com/funnel: "true"
```

This uses the same operator; no new infrastructure is needed.

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
bash scripts/security-scan.sh
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
TRIVY_IMAGE=ghcr.io/aquasecurity/trivy:0.70.0 bash scripts/security-scan.sh
```

### Known False Positives
Both Trivy (`trivy-report.sarif`) and Semgrep (`semgrep-report.sarif`) may report Kubernetes security findings (missing `securityContext`, `runAsNonRoot`, etc.) in raw YAML files. These are **expected false positives** because Kustomize patches inject the hardening at build time. The authoritative validation is always the **rendered manifest scan** (`trivy-rendered.sarif`), which evaluates the actual state sent to the Kubernetes API server.

We intentionally keep the K8s rules active in both Trivy and Semgrep as a safety net: if a Deployment is accidentally removed from `kustomization.yaml` patches, the raw-file scan will immediately flag the unhardened manifest.
