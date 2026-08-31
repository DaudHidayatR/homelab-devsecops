# Minimal Rootless Kubernetes & Istio Lab

A minimal, rootless local development environment using `kind` and Istio. Designed for learning service mesh basics without heavy resource overhead.

## Prerequisites
- Linux OS
- Rootless Docker *(Note: Podman can also be used by setting `KIND_EXPERIMENTAL_PROVIDER=podman`)*
- `kind` CLI
- `kubectl` CLI *(Kustomize is built-in since v1.14; no separate install needed)*
- `istioctl` CLI
- `helm` CLI *(fallback only; Flux manages OpenBao declaratively)*
- `flux` CLI *(optional; enables GitOps reconciliation. Install from [fluxcd.io](https://fluxcd.io/flux/installation/))*

## Project Structure

All desired cluster state lives below `kubernetes/`:

- `kubernetes/clusters/homelab/flux/`: ordered Flux reconciliation layers.
- `kubernetes/clusters/homelab/bootstrap/`: namespaces and local kind cluster configuration.
- `kubernetes/clusters/homelab/cluster-resources/`: cluster-scoped RBAC, storage, networking, and admission resources.
- `kubernetes/clusters/homelab/platform/`: OpenBao, Istio, and future platform services.
- `kubernetes/clusters/homelab/apps/`: application-owned manifests.
- `kubernetes/clusters/homelab/operations/`: operational Jobs and CronJobs.
- `kubernetes/clusters/homelab/cluster-policies/`: policy and governance sources.
- `kubernetes/components/`: reusable Kustomize components.
- `kubernetes/scripts/`: validation, diff, and health wrappers.
- `config.env`: local script configuration.

## Usage
1. Customize `config.env` if you want to change cluster names, namespaces, or image versions.
2. Deploy the lab with Make:
   ```bash
   make up
   ```
   Or invoke the lifecycle command directly:
   ```bash
   ./scripts/homelab cluster up
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

Flux bootstraps at `kubernetes/clusters/homelab` and reconciles ordered layers: bootstrap, cluster resources, platform, cluster policies, operations, then apps.

### Setup Modes

`make up` is the simple entrypoint, but it can complete in different modes depending on local tools and values in `config.env`.

| Condition | Deployment behavior | Required inputs | What remains manual |
|---|---|---|---|
| `flux` CLI is installed, `flux check --pre` passes, and `GITHUB_USER` + `GITHUB_TOKEN` are set | Flux bootstraps from GitHub and reconciles `kubernetes/clusters/homelab` | `GITHUB_USER`, `GITHUB_TOKEN` | OpenBao init/unseal |
| Flux bootstrap succeeds | Flux GitRepository watches branch `main`; every merge to `main` reconciles automatically | none | — |
| Flux prerequisites are missing | Setup stops before applying desired state | working Flux and GitHub credentials | Resolve the reported prerequisite and rerun `make up` |
| `TAILSCALE_CLIENT_ID` and `TAILSCALE_CLIENT_SECRET` are set | Tailscale namespace/OAuth Secret/operator are installed; OpenBao service is annotated; Serve config/watcher are applied | Tailscale OAuth client credentials | Tailnet Lock signing may still be required via `make tailscale-sign` |
| Tailscale credentials are absent | Tailscale installation is skipped | none | Use port-forwarding or run `make tailscale` after credentials are configured |
| Fresh OpenBao install | OpenBao pod is deployed but sealed/uninitialized | deployed OpenBao pod | Run `scripts/homelab openbao bootstrap` |
| Existing initialized OpenBao | Bootstrap/status scripts can unseal and reconcile idempotent parts | root/admin token or local backup files | Re-run `make openbao-policies` after policy changes |

After `make up`, the summary reports Flux, semver, Tailscale, and OpenBao bootstrap state.

### Operational script map

Detailed command, Tailscale access, and recovery guidance lives in [`scripts/README.md`](scripts/README.md).

#### Tracked documentation and simplification work

[GitHub issue #51](https://github.com/DaudHidayatR/homelab-devsecops/issues/51) tracks the remaining behavior-preserving script documentation and simplification work:

- keep the operational script catalog and `make up` phase/mode documentation accurate;
- clarify the OpenBao and Tailscale primary, manual, and recovery lifecycles;
- identify shared phase/policy helpers where they reduce duplication without changing the supported `make up` UX; and
- make the completed deployment mode explicit to operators.

Runtime, lifecycle, persistence, security-gate, and CI defects tracked in [issue #57](https://github.com/DaudHidayatR/homelab-devsecops/issues/57) are explicitly excluded from this documentation/simplification entry and must not be duplicated here.

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
| Headlamp | `config.env: HEADLAMP_IMAGE` / `HEADLAMP_VERSION` | `kubernetes/clusters/homelab/apps/headlamp/deployment.yaml` |
| Sample App | `config.env: SAMPLE_APP_IMAGE` | `kubernetes/clusters/homelab/apps/sample-app/deployment.yaml` |

To upgrade a component, update both `config.env` and the image field in the corresponding manifest. Version pinning ensures reproducible deployments across environments.

No tagging step is required. Flux watches branch `main`; merging a signed PR deploys.

## GitOps with Flux CD

This project uses [Flux CD](https://fluxcd.io) to automatically reconcile cluster state with this Git repository.

### Enabling Flux

1. Install the Flux CLI: https://fluxcd.io/flux/installation/
2. Add your GitHub credentials to `config.env`:
   ```bash
   GITHUB_USER="your-github-username"
   GITHUB_TOKEN="ghp_xxxxxxxxxxxx"
   ```
3. Run `make up` — `scripts/homelab cluster up` bootstraps Flux after creating the cluster.

### How Flux Works Here

| Flux Resource | Purpose |
|-------------|---------|
| `flux/kustomizations/00-bootstrap.yaml` | Reconciles namespaces and bootstrap prerequisites |
| `flux/kustomizations/10-cluster-resources.yaml` | Reconciles cluster-scoped RBAC and future storage/network resources |
| `flux/kustomizations/20-platform.yaml` | Reconciles OpenBao and Istio |
| `flux/kustomizations/30-openbao-config.yaml` | Publishes versioned OpenBao policy sources after the OpenBao platform layer |
| `flux/kustomizations/40-cluster-policies.yaml` | Reconciles deployable cluster policies |
| `flux/kustomizations/50-operations.yaml` | Reconciles operational workloads |
| `flux/kustomizations/60-apps.yaml` | Reconciles sample-app and Headlamp |

### Deployment Model: Branch-Main (decision 2026-08-31)

This project uses **branch-main deployment via Flux**. One system controls what gets deployed:

| System | What it watches | Triggers deploy on `main` push? |
|---|---|---|
| **GitHub Actions CI/CD** | `main` pushes | No — CI validates only; the deploy job runs against the declared branch-main source |
| **Flux Source Controller** | Branch `main` | **Yes** |

Flux's `GitRepository` watches `ref.branch: main`. Every signed merge to `main` reconciles automatically; rollback is `git revert` on `main`. There is no runtime ref switching, no tag selector, and no `make tag` flow.

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
4. The job declares the branch-main `GitRepository` (idempotent `kubectl apply`), then applies Kustomizations.
5. Flux's source controller fetches `main` and reconciles.
6. The job waits for both Kustomizations to report `Ready`.
7. A smoke test prints pod status and Flux resource health.

### One-Time Setup

- **[VPS Tailscale Setup](../../../document-project/web-documentasi/devsecops-homelab/template-wiki/Wiki/Concepts/network-and-trust-boundaries.md)** — Install Tailscale on the VPS host,
  get its Tailscale IP, and verify connectivity.
- **CI Deploy Secrets** — Set production secret `TS_AUTHKEY` to an ephemeral,
  reusable, pre-signed Tailscale auth key (`tskey-auth-...`) because Tailnet Lock is
  enabled. An API key (`ks...`) is not a node auth key and will be rejected. Also encode
  the kubeconfig and configure it as the production `KUBECONFIG` secret.
- **[Tailscale VPS Strategy](../../../document-project/web-documentasi/devsecops-homelab/template-wiki/Wiki/Entities/tailscale.md)** — Full reference including
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


## Accessing OpenBao (Secret Management)
OpenBao is deployed to the `openbao` namespace via the official Helm chart using **single-node raft** storage. The lab listener serves HTTP inside the cluster, while Tailscale Serve provides external HTTPS access.

### First-Run OpenBao Bootstrap

OpenBao initialization and unseal are intentionally manual. This keeps root tokens and unseal keys out of Git while Flux manages the chart.

### OpenBao operational lifecycle

| Step | Command/resource | Purpose | Notes |
|---|---|---|---|
| Deploy platform | `make up` | Create the kind cluster and deploy OpenBao | OpenBao is deployed but not initialized/unsealed |
| Initialize/unseal | `scripts/homelab openbao bootstrap` | Initialize if needed, unseal, enable KV v2/SSH/Kubernetes/userpass/AppRole, apply baseline policies | Stores root/unseal material under `.runtime-backups/openbao/` |
| Reconcile policies | `make openbao-policies` | Re-apply the explicit registry under `kubernetes/clusters/homelab/platform/openbao/configuration/policies/` | Safe after policy changes |
| Create human users | `OPENBAO_USER=alice OPENBAO_PASSWORD='...' OPENBAO_POLICY=user-default OPENBAO_SSH=true make openbao-create-user` | Create/update a userpass user with one or more policies and optional SSH signing role | No default human user is created unless explicitly requested |
| Create machine access | `make openbao-create-approle ROLE=ci-robot POLICY=ci-deployer` | Create AppRole with response-wrapped single-use SecretID | No default AppRole is created unless explicitly requested |

Default credential behavior is secure by default: `scripts/homelab openbao bootstrap` does **not** create a standing default admin user or default `ci-robot` AppRole unless `OPENBAO_CREATE_DEFAULT_ADMIN=true` or `OPENBAO_CREATE_DEFAULT_APPROLE=true` is set for that run.

Fresh cluster sequence:

1. Deploy the cluster and infrastructure:
   ```bash
   make up
   ```
2. Wait for the OpenBao pod:
   ```bash
   kubectl wait --for=condition=Ready pod/openbao-0 -n openbao --timeout=300s
   ```
3. Initialize, unseal, configure auth methods, and apply OpenBao policies:
   ```bash
   scripts/homelab openbao bootstrap
   ```

The script stores sensitive bootstrap material under `.runtime-backups/openbao/`. Keep it out of Git, preserve `0600` permissions, and back it up securely if the lab state matters.

Useful follow-up commands:
```bash
make openbao-status
make openbao-policies
OPENBAO_USER=alice OPENBAO_PASSWORD='change-me' OPENBAO_POLICY=user-default OPENBAO_SSH=true make openbao-create-user
make openbao-create-approle ROLE=ci-robot POLICY=ci-deployer
```

### Troubleshooting First Run

- File audit logging is skipped: add or verify a writable `/openbao/audit` path in the OpenBao pod, then rerun `scripts/homelab openbao bootstrap`.
- Userpass or AppRole auth is missing: rerun `scripts/homelab openbao bootstrap`; auth backend enablement is idempotent.
- OpenBao pod is crash-looping with `server gave HTTP response to HTTPS client`: confirm `kubernetes/clusters/homelab/platform/openbao/release/values.yaml` uses `scheme: HTTP` for probes and `tlsDisable: true`.

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

### OpenBao integrated-storage Raft recovery

Use this process only to recover OpenBao secret data after its Raft PVC was lost or corrupted. A pod restart with an intact PVC does not trigger recovery; unseal the existing OpenBao instance instead.

> **Recovery boundary:** OpenBao Raft data and Tailscale identity are unrelated. Never pass a Raft snapshot to `make recover` or `scripts/homelab tailscale restore`. Never apply a Tailscale `operator.json` backup to OpenBao or copy it into `/openbao/data`.

**Prerequisites and authoritative source**

- An independently stored snapshot created from the source OpenBao cluster with `bao operator raft snapshot save`. This binary snapshot is the authoritative OpenBao data backup.
- The source cluster's matching Shamir unseal key and an administrative token, stored securely outside the destroyed cluster.
- A replacement OpenBao pod using integrated Raft storage, plus `kubectl` access. The repository does not yet create, validate, or restore Raft snapshots automatically.

**Creating a Raft snapshot (backup)**

The snapshot is the only portable OpenBao data backup; take it regularly and store it outside the pod and the PVC. `bao operator raft snapshot save` requires a live, unsealed cluster and an administrative token (the root token in `.runtime-backups/openbao/root-token.txt` works).

```bash
export OPENBAO_TOKEN="$(<.runtime-backups/openbao/root-token.txt)"
install -d -m 0700 /secure/openbao-snapshots
kubectl exec -n openbao openbao-0 -- \
  env BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN="$OPENBAO_TOKEN" \
  bao operator raft snapshot save /tmp/openbao-raft.snap
kubectl cp openbao/openbao-0:/tmp/openbao-raft.snap /secure/openbao-snapshots/openbao-raft-$(date +%Y%m%d-%H%M%S).snap
kubectl exec -n openbao openbao-0 -- rm -f /tmp/openbao-raft.snap
unset OPENBAO_TOKEN
```

> **Cautions**
> - The snapshot is **not** a seal/unseal backup. It restores OpenBao data only; the unseal key and an administrative token are restored separately and must be kept with the snapshot.
> - Never store the snapshot only inside the pod (`/tmp`) or only on the PVC — both are destroyed with the cluster. Keep it on a host path or object store outside the cluster.
> - Verify the snapshot is a real OpenBao Raft snapshot (`file openbao-raft-*.snap` shows a snapshot archive), not a Tailscale `operator.json` backup, before you rely on it or restore it.
> - Restoring is destructive: `bao operator raft snapshot restore` replaces the current cluster state. Only restore into a fresh replacement, or you will lose writes made after the snapshot.

`.runtime-backups/openbao/` contains bootstrap credentials and principal metadata. It is **not** a Raft data backup and cannot recreate stored secrets by itself. Likewise, the OpenBao PVC is live state, not a portable snapshot.

**Ordered restore procedure**

1. Stop writes and preserve the failed PVC before changing anything. Confirm that the selected file is the expected binary Raft snapshot, not a Tailscale JSON backup.
2. Deploy a clean replacement. If the same cluster rebuild must also preserve Tailscale identity, complete the Tailscale identity procedure below first; it performs the cluster deployment. Otherwise run `make up`. Wait for `openbao-0`, then initialize and unseal that temporary OpenBao instance with `scripts/homelab openbao bootstrap`. This supplies a live authenticated endpoint for the restore.
3. Copy the snapshot into the pod and restore it with the current temporary root token:
   ```bash
   export OPENBAO_TOKEN="$(<.runtime-backups/openbao/root-token.txt)"
   kubectl cp /secure/path/openbao-raft.snap openbao/openbao-0:/tmp/openbao-raft.snap
   kubectl exec -n openbao openbao-0 -- \
     env BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN="$OPENBAO_TOKEN" \
     bao operator raft snapshot restore -force /tmp/openbao-raft.snap
   unset OPENBAO_TOKEN
   ```
   `-force` is required when the clean replacement has different Shamir keys; it bypasses the seal-key consistency check. Use it only with a trusted snapshot whose original unseal key is available.
4. The restored data uses the **source snapshot's** Shamir seal. Restore the source unseal key and administrative token to `.runtime-backups/openbao/` with `0600` permissions, then unseal with the source key:
   ```bash
   install -m 0600 /secure/path/source-unseal-key.txt .runtime-backups/openbao/unseal-key.txt
   install -m 0600 /secure/path/source-root-token.txt .runtime-backups/openbao/root-token.txt
   UNSEAL_KEY="$(<.runtime-backups/openbao/unseal-key.txt)"
   kubectl exec -n openbao openbao-0 -- \
     env BAO_ADDR=http://127.0.0.1:8200 bao operator unseal "$UNSEAL_KEY"
   unset UNSEAL_KEY
   ```
   Never use Tailscale OAuth or operator identity material here.
5. Remove `/tmp/openbao-raft.snap` from the pod after verification and retain the external snapshot according to the backup policy.

**Success checks**

```bash
export OPENBAO_TOKEN="$(<.runtime-backups/openbao/root-token.txt)"
make openbao-status
kubectl exec -n openbao openbao-0 -- \
  env BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN="$OPENBAO_TOKEN" \
  bao operator raft list-peers
# Read one known pre-snapshot secret or policy, then:
unset OPENBAO_TOKEN
```

Success is observable when status reports `initialized: true`, `sealed: false`, and `storage_type: raft`; `list-peers` shows `openbao-0` as the single leader; and a known pre-snapshot secret or policy can be read. Follow the upstream [OpenBao Raft snapshot documentation](https://openbao.org/docs/commands/operator/raft/#snapshot) and rehearse this procedure before relying on it.

### Important notes

- **Credential material is not data backup:** preserve the unseal key and administrative access material, but also take independent Raft snapshots if OpenBao data matters.
- **Data persistence:** OpenBao uses Raft at `/openbao/data` on a PVC. Data survives pod restarts and pod replacement (the StatefulSet recreates `openbao-0` on the same PVC), but is lost when the kind cluster is destroyed unless a separate Raft snapshot or tested volume backup exists. Take snapshots with `bao operator raft snapshot save` and store them outside the pod and PVC; see the [Raft recovery procedure](#openbao-integrated-storage-raft-recovery) and the [pod-replacement verification runbook](kubernetes/scripts/openbao-raft-persistence-verification.md).
- **TLS termination:** OpenBao serves HTTP inside the cluster for this lab. Tailscale Serve terminates HTTPS for tailnet browser access.

## Tailscale Private Access (Recommended)

Admin services are annotated for automatic tailnet exposure via the Tailscale Kubernetes Operator.

Primary path: encrypt the operator OAuth credentials once with SOPS (`make tailscale-encrypt` — see `tailscale/README.md`), or set `TAILSCALE_CLIENT_ID`/`TAILSCALE_CLIENT_SECRET` for one bootstrap and create the encrypted source immediately afterward, then run:

```bash
make up
```

The operator install is Flux-owned (HelmRelease `tailscale-operator`, chart 1.102.3). `scripts/homelab cluster up` delivers the OAuth Secret (SOPS first, one-bootstrap environment fallback), fails if neither source is usable, and verifies the rollout; tailnet access is declared with tailscale-class Ingresses (`headlamp-tailnet`, `openbao-tailnet`) instead of imperative `tailscale serve` calls.

> **NetworkPolicy limit:** this kind cluster keeps the default kindnetd CNI. Any
> NetworkPolicy committed here is CI-validated declarative intent only and is **not
> enforced at runtime**. PSA and Kyverno admission checks do not replace a policy-capable
> data plane. Switch to the researched Cilium/Calico path before running untrusted
> workloads that require segmentation.

Manual Tailscale install and Serve repair:

```bash
make tailscale          # verify the Flux-managed operator
scripts/homelab tailscale status
scripts/homelab tailscale check
```

Use this manual path when you intentionally skipped Tailscale during `make up` or are repairing Serve configuration. It does not restore operator identity or any OpenBao state; use the Tailscale identity procedure below for a destructive cluster rebuild. Detailed Tailscale guidance is in [`scripts/README.md`](scripts/README.md).

Once the operator is running, access admin UIs directly from any device on your tailnet:

   | Service | Tailnet URL |
   |---------|-------------|
   | Headlamp | `https://headlamp-headlamp.<tailnet>.ts.net` |
   | OpenBao  | `https://openbao-openbao.<tailnet>.ts.net/ui/` |

3. No port-forwarding, SSH tunnels, or public IPs required.

### Tailscale identity recovery during cluster rebuild

**Purpose and trigger:** preserve the Tailscale Kubernetes operator's device identity when the kind cluster must be destroyed or has already been lost. Use `make redeploy` instead for normal application changes.

> **Recovery boundary:** `make recover` is Tailscale identity recovery, not full-cluster data recovery. It restores Kubernetes Secret `tailscale/operator` and, when present in the backup, `tailscale/operator-oauth`; it does not restore OpenBao's PVC, Raft data, secrets, or bootstrap credentials. Do not pass an OpenBao snapshot or `.runtime-backups/openbao/` to this command. For OpenBao data recovery (pod replacement, PVC loss, or a destroyed cluster), use the [OpenBao Raft snapshot procedure](#openbao-integrated-storage-raft-recovery) — the PVC at `/openbao/data` survives pod replacement only, and a Raft snapshot stored outside the pod/PVC is the only portable backup.
>
> **Proxy (`ts-*`) identities are NOT restored.** Teardown writes `all-secrets.json` — a snapshot of every Secret in the `tailscale` namespace — but recovery never consumes it. `all-secrets.json` exists for forensics and as the input to the intentional `scripts/homelab tailscale reset` flow; it is not a recovery artifact. Proxy identity Secrets (`ts-*`) are owned and recreated by the Tailscale Kubernetes operator with per-rebuild randomized names, so restoring them by name is unsupported: after a rebuild, proxy devices re-register with the operator and appear as new devices. If Tailnet Lock is enabled, sign the new proxy nodes after recovery (step 4 below).

**Prerequisites and authoritative source**

- `kind`, `kubectl`, `python3`, the repository configuration, and working Flux prerequisites.
- If no live cluster exists, a validated `.runtime-backups/tailscale/<timestamp>/operator.json`; this Secret export is the authoritative Tailscale identity backup. Optional `operator-oauth.json` restores OAuth configuration. Other files in the backup directory (including `all-secrets.json`) are ignored by recovery: proxy `ts-*` identities are not restored.
- If a live cluster exists, the command first creates a fresh backup from live Secret `tailscale/operator` and intentionally uses that new path instead of the older supplied path.

**Ordered recovery steps**

1. Run the selected recovery target:
   ```bash
   BACKUP_DIR=.runtime-backups/tailscale/<timestamp> make recover
   ```
2. The target validates operator identity keys. With a live cluster, it atomically backs up Tailscale Secrets before deleting the cluster and refuses to continue if required identity is missing.
3. It creates a bare kind cluster, restores `tailscale/operator` before the operator starts, then runs normal Flux bootstrap and workload reconciliation.
4. If Tailnet Lock requires it, sign newly registered proxy nodes:
   ```bash
   scripts/homelab tailscale sign --sudo
   scripts/homelab tailscale status
   ```

**Success checks**

```bash
kubectl rollout status deployment/operator -n tailscale --timeout=120s
kubectl get secret operator -n tailscale
scripts/homelab tailscale check
```

Success is observable when the operator rollout completes, the restored Secret exists, `tailscale check` passes, and the Admin Console shows the existing operator device identity rather than a new duplicate such as `tailscale-operator-1`. Proxy devices reappear as new devices after recovery (their `ts-*` identity Secrets are not restored by design); sign them if Tailnet Lock is enabled, then re-run Serve configuration.

If Tailscale devices were deleted manually in the Tailscale Admin Console, reset the stale Kubernetes identities and let the proxies register fresh:

```bash
scripts/homelab tailscale reset
scripts/homelab tailscale sign
scripts/homelab tailscale status
scripts/homelab tailscale check
```

Tailnet Lock is enabled in this environment. Any newly registered Kubernetes proxy node must be signed before DNS/connectivity is fully available:

```bash
scripts/homelab tailscale sign
```

For a VPS reboot, the cluster should recover as long as the container runtime, kind node, and host Tailscale daemon restart normally. Re-run Serve configuration and access checks after proxy restarts:

```bash
scripts/homelab tailscale check
```

For a full VPS rebuild/recreate, also preserve the host Tailscale identity from `/var/lib/tailscale` before deleting the VPS. Otherwise the VPS itself becomes a new Tailscale device.

### Future Public Access

To expose a service to the public internet, add the `tailscale.com/funnel: "true"` annotation to its Tailscale Ingress. This uses the same operator; no new infrastructure is needed.

## Tear Down
To destroy the local infrastructure and free up resources, use the lifecycle command:
```bash
scripts/homelab cluster down
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
scripts/homelab security scan
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
TRIVY_IMAGE=ghcr.io/aquasecurity/trivy:0.70.0 scripts/homelab security scan
```

### Known False Positives
Both Trivy (`trivy-report.sarif`) and Semgrep (`semgrep-report.sarif`) may report Kubernetes security findings (missing `securityContext`, `runAsNonRoot`, etc.) in raw YAML files. These are **expected false positives** because Kustomize patches inject the hardening at build time. The authoritative validation is always the **rendered manifest scan** (`trivy-rendered.sarif`), which evaluates the actual state sent to the Kubernetes API server.

We intentionally keep the K8s rules active in both Trivy and Semgrep as a safety net: if a Deployment is accidentally removed from `kustomization.yaml` patches, the raw-file scan will immediately flag the unhardened manifest.
