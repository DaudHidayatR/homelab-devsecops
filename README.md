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
   ./scripts/cluster/setup.sh
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

Components are deployed via **Flux CD** when `GITHUB_TOKEN` and `GITHUB_USER` are configured. Flux continuously reconciles `infrastructure/` first, then `apps/` after infrastructure is ready. If Flux is not available, `scripts/cluster/setup.sh` falls back to applying `infrastructure/` then `apps/` sequentially via `kubectl apply -k`.

### Setup Modes

`make up` is the simple entrypoint, but it can complete in different modes depending on local tools and values in `config.env`.

| Condition | Deployment behavior | Required inputs | What remains manual |
|---|---|---|---|
| `flux` CLI is installed, `flux check --pre` passes, and `GITHUB_USER` + `GITHUB_TOKEN` are set | Flux bootstraps from GitHub and reconciles `clusters/kind` | `GITHUB_USER`, `GITHUB_TOKEN` | OpenBao init/unseal and ESO OpenBao store activation |
| Flux bootstrap succeeds and `FLUX_GIT_TAG` is set | Flux GitRepository is patched to watch semver tags instead of branch `main` | `FLUX_GIT_TAG`, for example `>=0.0.0` | Push a semver tag to deploy new changes |
| `flux` is missing, Flux preflight fails, or GitHub credentials are absent | `scripts/cluster/setup.sh` falls back to direct `kubectl apply -k infrastructure` then `kubectl apply -k apps` | working `kubectl` context | No continuous GitOps reconciliation; run `make sync` or `kubectl apply -k` for updates |
| `TAILSCALE_CLIENT_ID` and `TAILSCALE_CLIENT_SECRET` are set | Tailscale namespace/OAuth Secret/operator are installed; OpenBao service is annotated; Serve config/watcher are applied | Tailscale OAuth client credentials | Tailnet Lock signing may still be required via `make tailscale-sign` |
| Tailscale credentials are absent | Tailscale installation is skipped | none | Use port-forwarding or run `make tailscale` after credentials are configured |
| Fresh OpenBao install | OpenBao pod is deployed but sealed/uninitialized | deployed OpenBao pod | Run `bash scripts/openbao/bootstrap.sh`, then seed app secrets and apply ESO stores |
| Existing initialized OpenBao | Bootstrap/status scripts can unseal and reconcile idempotent parts | root/admin token or local backup files | Re-run `make openbao-policies` after policy changes |

After `make up`, check the final summary printed by `scripts/cluster/setup.sh`. It reports whether the run used Flux GitOps or direct apply fallback, whether semver mode is active, whether Tailscale was enabled, and which OpenBao/ESO steps are still pending.

### Operational script map

Detailed script purpose, prerequisites, idempotency, and verification guidance lives in [`scripts/README.md`](scripts/README.md). Policy behavior is documented in [`policies/README.md`](policies/README.md), and Tailscale access/recovery details live in [`tailscale/README.md`](tailscale/README.md).

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
3. Run `make up` — `scripts/cluster/setup.sh` will bootstrap Flux after creating the cluster.

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
   kubectl port-forward -n headlamp service/headlamp 8080:80
   ```
2. In a new terminal, generate a login token:
   ```bash
   kubectl create token headlamp-admin -n headlamp
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
OpenBao is deployed to the `openbao` namespace via the official Helm chart using **single-node raft** storage. The lab listener serves HTTP inside the cluster, while Tailscale Serve provides external HTTPS access.

### First-Run OpenBao Bootstrap

OpenBao initialization and unseal are intentionally manual. This keeps root tokens and unseal keys out of Git while still letting Flux manage the chart and External Secrets Operator controller.

### OpenBao operational lifecycle

| Step | Command/resource | Purpose | Notes |
|---|---|---|---|
| Deploy platform | `make up` | Create kind cluster and deploy OpenBao/ESO controllers | OpenBao is deployed but not initialized/unsealed |
| Initialize/unseal | `bash scripts/openbao/bootstrap.sh` | Initialize if needed, unseal, enable KV v2/SSH/Kubernetes/userpass/AppRole, apply baseline policies | Stores root/unseal material under `.runtime-backups/openbao/` |
| Reconcile policies | `make openbao-policies` | Re-apply registered policies under `policies/openbao/` and explicit Kubernetes auth/entity mappings | Safe after policy changes |
| Create human users | `OPENBAO_USER=alice OPENBAO_PASSWORD='...' OPENBAO_POLICY=user-default OPENBAO_SSH=true make openbao-create-user` or `OPENBAO_POLICY=user-default,system-admin,user-ssh` | Create/update a userpass user with one or more policies and optional SSH signing role | No default human user is created unless explicitly requested |
| Create machine access | `make openbao-create-approle ROLE=ci-robot POLICY=ci-deployer` | Create AppRole with response-wrapped single-use SecretID | No default AppRole is created unless explicitly requested |
| Seed app secret | `bash scripts/openbao/store-rabbitmq.sh` | Store RabbitMQ credentials in OpenBao KV v2 | Source path is `secret/data/messaging/rabbitmq` |
| Activate ESO sync | `kubectl apply -k infrastructure/external-secrets/stores` | Create ClusterSecretStore/ExternalSecret resources | Run only after OpenBao is initialized, unsealed, and seeded |
| Verify output | `kubectl get secret rabbitmq-credentials -n messaging` | Confirm Kubernetes Secret was generated by ESO | Restart RabbitMQ if it started before the Secret existed |

Default credential behavior is secure by default: `scripts/openbao/bootstrap.sh` does **not** create a standing default admin user or default `ci-robot` AppRole unless `OPENBAO_CREATE_DEFAULT_ADMIN=true` or `OPENBAO_CREATE_DEFAULT_APPROLE=true` is set for that run.

Fresh cluster sequence:

1. Deploy the cluster and infrastructure:
   ```bash
   make up
   ```
2. Wait for the OpenBao pod:
   ```bash
   kubectl wait --for=condition=Ready pod/openbao-0 -n openbao --timeout=300s
   ```
3. Initialize, unseal, enable KV v2, configure Kubernetes/userpass/AppRole auth, apply OpenBao policies, seed safe KV paths, and create the ESO Kubernetes auth role:
   ```bash
   bash scripts/openbao/bootstrap.sh
   ```
   The script stores sensitive bootstrap material under `.runtime-backups/openbao/`:
   - `.runtime-backups/openbao/root-token.txt`
   - `.runtime-backups/openbao/unseal-key.txt`

   These files are local secrets. Keep them out of Git, preserve `0600` permissions, and back them up securely if you need to keep the lab state.

   Useful OpenBao follow-up commands:
   ```bash
   make openbao-status
   make openbao-policies
   OPENBAO_USER=alice OPENBAO_PASSWORD='change-me' OPENBAO_POLICY=user-default OPENBAO_SSH=true make openbao-create-user
   OPENBAO_USER=sagash OPENBAO_PASSWORD='change-me' OPENBAO_POLICY=user-default,system-admin,user-ssh OPENBAO_SSH=true make openbao-create-user
   make openbao-create-approle ROLE=ci-robot POLICY=ci-deployer
   ```

   `scripts/openbao/bootstrap.sh` does not create standing AppRole credentials by default. Set `OPENBAO_CREATE_DEFAULT_APPROLE=true` only when you intentionally want the default `ci-robot` role. After confirming a non-root admin user can perform required operations, secure or manually revoke the root token according to your recovery model.

4. Store or migrate RabbitMQ credentials into OpenBao KV v2:
   ```bash
   bash scripts/openbao/store-rabbitmq.sh
   ```
5. Apply the ESO store resources after OpenBao has been bootstrapped:
   ```bash
   kubectl apply -k infrastructure/external-secrets/stores
   ```
   These resources are intentionally excluded from the default `infrastructure/external-secrets/` phase because they depend on manual OpenBao bootstrap.
6. Verify the OpenBao-backed sync:
   ```bash
   kubectl get clustersecretstore openbao
   kubectl get externalsecret rabbitmq-credentials -n messaging
   kubectl get secret rabbitmq-credentials -n messaging
   ```
7. If RabbitMQ started before the secret existed, restart it after the secret syncs:
   ```bash
   kubectl rollout restart deployment/rabbitmq -n messaging
   kubectl rollout status deployment/rabbitmq -n messaging --timeout=180s
   ```

### Troubleshooting First Run

- `ClusterSecretStore/openbao` is not ready: confirm OpenBao is unsealed and `scripts/openbao/bootstrap.sh` completed successfully.
- ESO authentication fails: verify the bootstrap script configured `kubernetes_host=https://kubernetes.default.svc:443` and passed the Kubernetes service account CA as PEM.
- File audit logging is skipped: add or verify a writable `/vault/audit` path in the OpenBao pod, then re-run `scripts/openbao/bootstrap.sh`.
- Userpass or AppRole auth is missing: re-run `scripts/openbao/bootstrap.sh`; auth backend enablement is idempotent.
- OpenBao pod is crash-looping with `server gave HTTP response to HTTPS client`: confirm `infrastructure/openbao/values.yaml` uses `scheme: HTTP` for readiness/liveness probes and `tlsDisable: true`.
- `rabbitmq-credentials` is missing: confirm `scripts/openbao/store-rabbitmq.sh` stored `secret/data/messaging/rabbitmq`, then reconcile the ESO store resources.
- RabbitMQ is pending or crash-looping: create/sync `messaging/rabbitmq-credentials`, then restart the RabbitMQ deployment.

### Internal Access
Applications in the cluster can reach OpenBao at:
```
OPENBAO_ADDR=http://openbao.openbao.svc.cluster.local:8200
```

For local browser access:

1. Port-forward the OpenBao service:
   ```bash
   kubectl port-forward -n openbao svc/openbao 8200:8200
   ```
2. Open [http://localhost:8200](http://localhost:8200) in your browser.

### Important Notes
- **Back up bootstrap secrets carefully**: losing both the unseal key and recovery material means rebuilding the lab and recreating secrets.
- **Data Persistence**: OpenBao uses raft storage backed by a PVC. Data survives pod restarts but is lost when the kind cluster is destroyed.
- **TLS termination**: OpenBao serves HTTP inside the cluster for this lab. Tailscale Serve terminates HTTPS for tailnet browser access.

## Tailscale Private Access (Recommended)

Admin services are annotated for automatic tailnet exposure via the Tailscale Kubernetes Operator.

Primary path: set `TAILSCALE_CLIENT_ID` and `TAILSCALE_CLIENT_SECRET` in `config.env`, then run:

```bash
make up
```

When credentials are present, `scripts/cluster/setup.sh` creates the Tailscale namespace and OAuth Secret, installs the operator, annotates OpenBao, configures Tailscale Serve on proxy pods, and deploys the Serve watcher.

Manual fallback/recovery path:

```bash
make tailscale
./scripts/tailscale/configure-serve.sh
./scripts/tailscale/check-access.sh
```

Use the manual path when you intentionally skipped Tailscale during `make up`, are repairing Serve configuration, or are recovering after a cluster rebuild. See `tailscale/README.md` for OAuth, Tailnet Lock, proxy signing, and identity recovery details.

Once the operator is running, access admin UIs directly from any device on your tailnet:

   | Service | Tailnet URL |
   |---------|-------------|
   | Headlamp | `https://headlamp-headlamp.<tailnet>.ts.net` |
   | RabbitMQ | `https://messaging-rabbitmq.<tailnet>.ts.net` |
   | OpenBao  | `https://openbao-openbao.<tailnet>.ts.net/ui/` |

3. No port-forwarding, SSH tunnels, or public IPs required.

### Safe redeploy, reboot, and recovery

Use a non-destructive redeploy for normal app changes:

```bash
make redeploy
```

Do not use `make down && make up` for normal redeploys. `make down` deletes the kind cluster and can remove Kubernetes Tailscale identity state.

If a full cluster rebuild is required, use the ordered recovery target. It validates and restores Tailscale identity before Flux starts the operator:

```bash
BACKUP_DIR=.runtime-backups/tailscale/<timestamp> make recover
./scripts/tailscale/check-access.sh
```

If Tailscale devices were deleted manually in the Tailscale Admin Console, reset the stale Kubernetes identities and let the proxies register fresh:

```bash
./scripts/tailscale/reset-proxies.sh
./scripts/tailscale/sign-proxies.sh
./scripts/tailscale/configure-serve.sh
./scripts/tailscale/check-access.sh
```

Tailnet Lock is enabled in this environment. Any newly registered Kubernetes proxy node must be signed before DNS/connectivity is fully available:

```bash
./scripts/tailscale/sign-proxies.sh
```

For a VPS reboot, the cluster should recover as long as the container runtime, kind node, and host Tailscale daemon restart normally. Re-run Serve configuration and access checks after proxy restarts:

```bash
./scripts/tailscale/check-access.sh
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
./scripts/cluster/destroy.sh
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
bash scripts/security/scan.sh
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
TRIVY_IMAGE=ghcr.io/aquasecurity/trivy:0.70.0 bash scripts/security/scan.sh
```

### Known False Positives
Both Trivy (`trivy-report.sarif`) and Semgrep (`semgrep-report.sarif`) may report Kubernetes security findings (missing `securityContext`, `runAsNonRoot`, etc.) in raw YAML files. These are **expected false positives** because Kustomize patches inject the hardening at build time. The authoritative validation is always the **rendered manifest scan** (`trivy-rendered.sarif`), which evaluates the actual state sent to the Kubernetes API server.

We intentionally keep the K8s rules active in both Trivy and Semgrep as a safety net: if a Deployment is accidentally removed from `kustomization.yaml` patches, the raw-file scan will immediately flag the unhardened manifest.
