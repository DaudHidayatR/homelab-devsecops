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
- `infrastructure/`: Foundational cluster resources — namespaces (demo, messaging, openbao, istio-system), OpenBao (HelmRelease, NetworkPolicies), and Istio (HelmRelease + mTLS).
- `kind/`: Cluster bootstrapping configurations.
- `patches/`: Strategic merge patches applied to resources (e.g., Pod Security Standards labels on Namespaces).
- `apps/`: Flux-managed application overlays. Aggregates `apps/demo/`, `apps/rabbitmq/`, and `apps/headlamp/` through `apps/kustomization.yaml`.
- `apps/rabbitmq/`: RabbitMQ message broker manifests in a dedicated namespace (kept outside the mesh).
- `apps/headlamp/`: Kubernetes Web UI manifests for visual management.
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

Components are deployed via **Flux CD** when `GITHUB_TOKEN` and `GITHUB_USER` are configured. Flux continuously reconciles `infrastructure/` first, then `apps/` after infrastructure is ready. If Flux is not available, `setup.sh` falls back to applying `infrastructure/` then `apps/` sequentially via `kubectl apply -k`.

## Branch Management

GitHub's "Automatically delete head branches" is enabled on this repository. Every PR merge deletes the source branch automatically, keeping the branch list clean.

### Local Cleanup

Remove local tracking refs for deleted remote branches and delete merged local branches:
```bash
# Preview what would be deleted (safe, shows list only)
make prune-branches

# Delete local branches already merged into main
make prune-branches-force
```

## Versioning

All component image versions are defined directly in their respective manifests. The canonical version reference is `config.env`, which documents the currently deployed versions and is consumed by scripts at runtime:

| Component | Image Source | Controlled In |
|-----------|-------------|---------------|
| OpenBao | `config.env: OPENBAO_IMAGE` / `OPENBAO_CHART_VERSION` | `infrastructure/openbao/values.yaml` (Flux HelmRelease values) |
| Headlamp | `config.env: HEADLAMP_IMAGE` / `HEADLAMP_VERSION` | `apps/headlamp/headlamp.yaml` (Deployment image) |
| RabbitMQ | `config.env: RABBITMQ_IMAGE` | `apps/rabbitmq/core/deployment.yaml` (Deployment image) |
| Sample App | `config.env: SAMPLE_APP_IMAGE` | `apps/demo/sample-app/deployment.yaml` (Deployment image) |

To upgrade a component, update both `config.env` and the image field in the corresponding manifest. Version pinning ensures reproducible deployments across environments.

Tag the repository after each validated deployment:
```bash
git tag -a v1.0.0 -m "Baseline deployment"
git push origin v1.0.0
```

Or use the convenience Makefile target:
```bash
make tag v=1.0.1
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
| `clusters/kind/apps.yaml` | Reconciles the buildable `apps/` aggregate: demo app, RabbitMQ, and Headlamp |
| `infrastructure/openbao/helmrepository.yaml` | Indexes the OpenBao Helm chart repository |
| `infrastructure/openbao/helmrelease.yaml` | Declaratively installs/upgrades OpenBao |

### Deployment Model: Semver-Based

This project uses **semver-based deployment via Flux**. Two independent systems control what gets deployed:

| System | What it watches | Triggers deploy on `main` push? |
|---|---|---|
| **GitHub Actions CI/CD** | `v*` tag pushes only | No (deploy job is `skipped`) |
| **Flux Source Controller** | Semver tags on Git repo | **No (watches semver, not branch)** |

Flux's `GitRepository` is configured with `ref.semver.range: ">=0.0.0"` — it only reconciles when new semver tags appear. Pushing to `main` runs CI/CD validation but does **not** trigger deployment through either path.

Set `FLUX_GIT_TAG` in `config.env` to the semver range:

```bash
FLUX_GIT_TAG=">=0.0.0"
```

In semver mode:
- Pushes to `main` run scanning only — no deploy.
- Only `git tag v1.0.1 && git push origin v1.0.1` deploys.
- Instant rollback: `flux reconcile source git flux-system --source-ref=v1.0.0`
- Feature branches are disposable after PR merge — only `main` remains.

This is the recommended mode for a solo-dev GitOps workflow. If you need to change the range (e.g., to `">=1.0.0 <2.0.0"`), update `config.env` and re-run `make up`.

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

## CI/CD Auto-Deploy

Pushing a `v*` tag triggers the [IaC Security Pipeline](.github/workflows/IaC.yml) which runs
security gates (lint, secrets, misconfig, policy), then deploys via Flux reconciliation
through a GitHub Actions runner connected to the VPS over Tailscale.

Pushes to `main` run validation/scanning only — **no deploy**. Only `v*` tags deploy to
production:

### How It Works

1. You push a `v*` tag → the [IaC Security Pipeline](.github/workflows/IaC.yml) runs.
2. Security gates pass (lint, secrets, misconfig, policy).
3. The deploy job connects the runner to the tailnet with `tag:ci-runner`.
4. The job patches Flux's `GitRepository` to `ref.semver.range: ">=0.0.0"` (one-time, idempotent), then applies Kustomizations.
5. Flux's source controller detects the new semver tag and begins reconciliation.
6. The job waits for both Kustomizations to report `Ready`.
7. A smoke test prints pod status and Flux resource health.

### One-Time Setup

- **[VPS Tailscale Setup](wiki/docs/vps-tailscale-setup.md)** — Install Tailscale on the VPS host,
  get its Tailscale IP, and verify connectivity.
- **[CI Deploy Secrets](wiki/docs/ci-deploy-secrets.md)** — Create the Tailscale OAuth client for CI,
  encode the kubeconfig, and configure GitHub Environment secrets.
- **[Tailscale VPS Strategy](wiki/concepts/tailscale-vps-strategy.md)** — Full reference including
  security model, TLS cert handling, and troubleshooting.

### Manual Trigger

You can still trigger reconciliation locally:
```bash
make sync
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
4. Open [https://localhost:8200](https://localhost:8200) in your browser (accept the self-signed certificate warning).

### Important Notes
- **Back up the init output**: Store the root token and unseal key outside the cluster. Losing them means rebuilding the lab and recreating secrets.
- **Data Persistence**: OpenBao uses raft storage backed by a PVC. Data survives pod restarts but is lost when the kind cluster is destroyed.
- **No ingress in phase 1**: Access is intentionally limited to `kubectl port-forward` for a smaller, easier-to-audit setup.

### Optional phase-1 bootstrap
After unsealing, you can enable the minimum useful features from inside the pod:

```bash
kubectl exec -it -n openbao openbao-0 -- sh
export BAO_ADDR=https://127.0.0.1:8200
export BAO_SKIP_VERIFY=true
bao login <root_token>
bao secrets enable -path=secret kv-v2
bao auth enable kubernetes
bao write auth/kubernetes/config kubernetes_host="https://$KUBERNETES_SERVICE_HOST:$KUBERNETES_SERVICE_PORT"
```

### Internal Access
Applications in the cluster can reach OpenBao at:
```
OPENBAO_ADDR=https://openbao.openbao.svc.cluster.local:8200
BAO_SKIP_VERIFY=true  # self-signed cert in lab environment
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
   | Headlamp | `https://kube-system-headlamp.<tailnet>.ts.net` |
   | RabbitMQ | `https://messaging-rabbitmq.<tailnet>.ts.net` |
   | OpenBao  | `https://openbao-openbao.<tailnet>.ts.net/ui/` |

3. No port-forwarding, SSH tunnels, or public IPs required.

### Safe redeploy, reboot, and recovery

Use a non-destructive redeploy for normal app changes:

```bash
make redeploy
```

Do not use `make down && make up` for normal redeploys. `make down` deletes the kind cluster and can remove Kubernetes Tailscale identity state.

If a full cluster rebuild is required, preserve the Tailscale Kubernetes identity:

```bash
make down
./tailscale/restore-state.sh latest
make up
./scripts/configure-tailscale-serve.sh
./tailscale/check-access.sh
```

If Tailscale devices were deleted manually in the Tailscale Admin Console, reset the stale Kubernetes identities and let the proxies register fresh:

```bash
./tailscale/reset-proxies.sh
./tailscale/sign-proxies.sh
./scripts/configure-tailscale-serve.sh
./tailscale/check-access.sh
```

Tailnet Lock is enabled in this environment. Any newly registered Kubernetes proxy node must be signed before DNS/connectivity is fully available:

```bash
./tailscale/sign-proxies.sh
```

For a VPS reboot, the cluster should recover as long as the container runtime, kind node, and host Tailscale daemon restart normally. The in-cluster Tailscale Serve watcher re-applies Serve config after proxy pod restarts. Run this check after reboot:

```bash
./tailscale/check-access.sh
```

For a full VPS rebuild/recreate, also preserve the host Tailscale identity from `/var/lib/tailscale` before deleting the VPS. Otherwise the VPS itself becomes a new Tailscale device.

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
- `checkov-report.*` — Kubernetes IaC policy findings that mirror GitHub code scanning alerts
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
