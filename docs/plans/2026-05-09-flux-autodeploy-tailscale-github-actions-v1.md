# Auto-Deploy: Flux CD + Tailscale + GitHub Actions

**Date:** 2026-05-09
**Status:** Planned
**Branch:** `fix-ci-policy`
**Principles:** KISS, YAGNI, TDA, SRP

## Goal

Replace the stub deploy job in `.github/workflows/IaC.yml` with a working auto-deploy pipeline. When commits land on `main`, CI connects to the VPS-hosted kind cluster via Tailscale and triggers Flux reconciliation -- zero polling delay, zero public endpoints.

---

## Architecture

```
Git push to main
      │
      ▼
GitHub Actions (cloud runner)
  ├── lint / secrets / misconfig / policy (existing, unchanged)
  └── deploy (environment: production, approval-gated)
       ├── 1. tailscale/github-action@v3 → runner joins tailnet as tag:ci-runner
       ├── 2. curl install Flux CLI on runner
       ├── 3. kubectl configured with Tailscale-routed kubeconfig
       ├── 4. flux reconcile source git → force-refresh Git repo
       ├── 5. flux reconcile kustomization infrastructure → apply infra
       ├── 6. flux wait kustomization infrastructure --for=condition=ready
       ├── 7. flux reconcile kustomization apps → apply apps
       ├── 8. flux wait kustomization apps --for=condition=ready
       └── 9. Smoke test (kubectl get pods, flux get all)
                │
    Tailscale Mesh (WireGuard)
                │
                ▼
VPS host (tag:vps-k8s, Tailscale IP: 100.x.x.x)
  ├── tailscale client (on host, NOT the Kubernetes operator)
  └── kube-apiserver :6443 ← reachable via Tailscale IP
```

**Key distinction:** The Tailscale Kubernetes Operator (already in `setup.sh`) exposes *services* (Headlamp, RabbitMQ, OpenBao) to your tailnet. The **Tailscale host client** (new) makes the *kube-apiserver* reachable from CI runners. They serve different purposes and use separate OAuth clients.

---

## Approach Selection

### Chosen: Approach A -- Tailscale + Flux CLI from CI Runner

The GitHub Actions runner joins the tailnet via `tailscale/github-action@v3` with a dedicated OAuth client (`tag:ci-runner`). It installs Flux CLI, decodes a base64-encoded kubeconfig stored as a GitHub Environment secret, and runs `flux reconcile` + `flux wait`.

| Pros | Cons |
|------|------|
| Zero polling delay -- push triggers immediate reconciliation | Requires VPS Tailscale host setup (one-time) |
| Full health reporting via `flux wait --for=condition=ready` | Two separate OAuth clients to manage |
| Mirrors `make sync` pattern exactly -- consistent DX | Runner lifetime tied to workflow timeout |
| No public endpoints needed -- entire pipeline stays on tailnet | ~30-60s added for Tailscale connection setup |

### Why Not Alternatives

- **Approach B (SSH into VPS):** Adds SSH key management, loses CI-runner identity, harder to debug (logs on VPS).
- **Approach C (kubectl apply -k bypass Flux):** Inconsistent with GitOps model; Flux would revert manual applies.
- **Approach D (Webhook Receivers):** Requires public URL/ingress -- conflicts with private Tailscale architecture.

---

## Files to Create

### 1. `docs/vps-tailscale-setup.md` (NEW)

One-time setup guide for the VPS. Covers:
- Installing Tailscale on the VPS host: `curl -fsSL https://tailscale.com/install.sh | sh`
- Authenticating with auth key + tag: `sudo tailscale up --authkey=<KEY> --hostname=vps-k8s --advertise-tags=tag:vps-k8s`
- Enabling persistence: `sudo systemctl enable --now tailscaled`
- Verifying coexistence with rootless kind (CIDRs don't overlap: Tailscale = 100.64.0.0/10 vs kind = 10.244.0.0/16)
- Checking apiserver binds to `0.0.0.0:6443` (not just `127.0.0.1:6443`): `ss -tlnp | grep 6443`
- Adding VPS firewall rule for defense-in-depth: `sudo iptables -A INPUT -p tcp --dport 6443 ! -s 100.64.0.0/10 -j DROP`
- Extracting Tailscale IP: `tailscale ip -4`
- Testing connectivity from another tailnet device: `curl -k https://<vps-ts-ip>:6443/version`
- Troubleshooting reference: connection refused (apiserver bind), TLS errors (SAN issue), ACL blocks, DERP timeouts
- Full details in `wiki/concepts/tailscale-vps-strategy.md`

### 2. `docs/ci-deploy-secrets.md` (NEW)

GitHub Environment secrets reference covering the complete setup chain. Covers:

**A. Tailscale OAuth Client (Tailscale Admin Console)**
- Create separate OAuth client (not the Operator's): Settings → OAuth Clients → Generate
- Tags: `tag:ci-runner`, Scope: `Devices:Write`
- Store Client ID as `TS_OAUTH_CLIENT_ID`, Client Secret as `TS_OAUTH_SECRET` in GitHub Environment `production`

**B. Tailscale ACL Rules (Tailscale Admin Console)**
- Add rule: `{"action": "accept", "src": ["tag:ci-runner"], "dst": ["tag:vps-k8s:6443"]}`
- Add `tagOwners` entries for both tags
- Verify with `tailscale debug netmap`

**C. CI ServiceAccount RBAC (on the Cluster)**
- Apply `infrastructure/namespaces/ci-rbac.yaml` (dedicated `ci-deployer` SA with least-privilege Role, not cluster-admin)
- Generate token-based kubeconfig using the SA

**D. Kubeconfig Generation (on the VPS)**
- Extract raw kubeconfig, swap server to Tailscale IP (or MagicDNS name)
- **CRITICAL: Add `insecure-skip-tls-verify: true`** — the kind apiserver cert only has `127.0.0.1` in SANs (see wiki section 2.1 for the three solutions)
- When cluster is rebuilt, add `certSANs` to `kind/cluster.yaml` and remove `insecure-skip-tls-verify`
- Verify: `kubectl --kubeconfig=/tmp/ci-kubeconfig.yaml cluster-info`
- Base64-encode and store as `KUBECONFIG` secret

| Secret | Source | How to create |
|--------|--------|---------------|
| `TS_OAUTH_CLIENT_ID` | Tailscale Admin → OAuth Clients | Create OAuth client with `Devices:Write` scope, tag `tag:ci-runner` |
| `TS_OAUTH_SECRET` | Tailscale Admin → OAuth Clients | Copy from OAuth client creation |
| `KUBECONFIG` | VPS `~/.kube/config` (with ci-deployer SA) | `kubectl config view --raw \| sed ... \| base64 -w0` with `insecure-skip-tls-verify: true` |

### 2b. `infrastructure/namespaces/ci-rbac.yaml` (NEW)

Dedicated ServiceAccount for CI with least-privilege RBAC. Scoped to exactly what Flux reconciliation needs — not cluster-admin:

```yaml
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ci-deployer
  namespace: flux-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: ci-deployer
rules:
  - apiGroups: ["source.toolkit.fluxcd.io"]
    resources: ["*"]
    verbs: ["get", "list", "watch", "patch", "update"]
  - apiGroups: ["kustomize.toolkit.fluxcd.io"]
    resources: ["*"]
    verbs: ["get", "list", "watch", "patch", "update"]
  - apiGroups: ["helm.toolkit.fluxcd.io"]
    resources: ["*"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["namespaces", "pods", "services", "configmaps"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["apps"]
    resources: ["deployments", "statefulsets", "daemonsets"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["serviceaccounts"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ci-deployer
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: ci-deployer
subjects:
  - kind: ServiceAccount
    name: ci-deployer
    namespace: flux-system
```

---

## Files to Modify

### 3. `.github/workflows/IaC.yml` -- Replace stub deploy job

**Current (stub):**
```yaml
deploy:
  name: Deploy
  runs-on: ubuntu-latest
  needs: [lint, secrets, misconfig, policy]
  if: github.event_name == 'push' && (github.ref == 'refs/heads/main' || github.ref == 'refs/heads/master')
  timeout-minutes: 30
  environment: production
  steps:
    - uses: actions/checkout@v4
    - name: Deploy Infrastructure
      run: |
        echo "Add your Terraform apply / kubectl apply / Helm deploy steps here."
        echo "This job is gated by the environment: production approval."
```

**Replace with:**

```yaml
  deploy:
    name: Deploy (Flux reconcile via Tailscale)
    runs-on: ubuntu-latest
    needs: [lint, secrets, misconfig, policy]
    if: github.event_name == 'push' && (github.ref == 'refs/heads/main' || github.ref == 'refs/heads/master')
    timeout-minutes: 30
    environment: production
    steps:
      - uses: actions/checkout@v4

      - name: Connect to Tailscale
        uses: tailscale/github-action@v3
        with:
          oauth-client-id: ${{ secrets.TS_OAUTH_CLIENT_ID }}
          oauth-secret: ${{ secrets.TS_OAUTH_SECRET }}
          tags: tag:ci-runner

      - name: Install Flux CLI
        run: |
          curl -s https://fluxcd.io/install.sh | bash
          flux version --client

      - name: Setup kubeconfig
        run: |
          echo "${{ secrets.KUBECONFIG }}" | base64 -d > "$RUNNER_TEMP/kubeconfig"
          echo "KUBECONFIG=$RUNNER_TEMP/kubeconfig" >> "$GITHUB_ENV"

      - name: Verify cluster connectivity
        run: kubectl cluster-info

      - name: Reconcile Flux sources
        run: flux reconcile source git flux-system

      - name: Reconcile infrastructure
        run: |
          flux reconcile kustomization infrastructure
          flux wait kustomization infrastructure \
            --for=condition=ready \
            --timeout=5m

      - name: Reconcile apps
        run: |
          flux reconcile kustomization apps
          flux wait kustomization apps \
            --for=condition=ready \
            --timeout=5m

      - name: Smoke test
        run: |
          echo "=== Pod Status ==="
          kubectl get pods -A
          echo ""
          echo "=== Flux Resources ==="
          flux get all
```

Key design decisions:
- **`timeout-minutes: 30`** -- unchanged from existing stub; gives headroom for slow image pulls
- **`environment: production`** -- unchanged; gates deployment with required reviewers if configured
- **`flux wait --timeout=5m`** -- matches the existing `spec.timeout: 5m` on both Flux Kustomization CRDs
- **Kubeconfig in `$RUNNER_TEMP`** -- ephemeral, auto-cleaned by GitHub after job ends

### 4. `kind/cluster.yaml` -- Add certSANs for future rebuild

Add `certSANs` with Tailscale IP and MagicDNS name so TLS validation works without `insecure-skip-tls-verify` when the cluster is next rebuilt:

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: rootless-mesh
nodes:
  - role: control-plane
    extraPortMappings:
      - containerPort: 6443
        hostPort: 6443
        protocol: TCP
    kubeadmConfigPatches:
      - |
        apiVersion: kubeadm.k8s.io/v1beta3
        kind: ClusterConfiguration
        apiServer:
          certSANs:
            - "127.0.0.1"
            - "localhost"
            - "TAILSCALE_VPS_HOSTNAME_PLACEHOLDER"       # e.g., 100.87.123.45
            - "TAILSCALE_VPS_HOSTNAME_PLACEHOLDER.ts.net" # MagicDNS name
```

(Replace placeholders with actual values from `config.env` after VPS Tailscale is set up.)

### 5. `config.env.example` -- Add Tailscale + VPS hostname section

Add after the namespaces block (before `# --- Cluster ---`):

```bash
# --- Tailscale Operator ---
# Set both to auto-install the Tailscale Kubernetes Operator during setup.
# Leave empty to skip Tailscale installation (manual port-forward access only).
# Get credentials: https://login.tailscale.com/admin/settings/oauth
# Required scope: Devices → Write
TAILSCALE_CLIENT_ID=""
TAILSCALE_CLIENT_SECRET=""

# --- Tailscale VPS Host (for CI/CD deploy) ---
# The hostname of the VPS running the kind cluster, as registered in Tailscale.
# Used in documentation and kubeconfig generation for CI runners.
# Run 'tailscale status' on the VPS to find its hostname.
TAILSCALE_VPS_HOSTNAME=""
```

### 6. `config.env` -- Add `TAILSCALE_VPS_HOSTNAME`

The existing Operator section already has `TAILSCALE_CLIENT_ID` and `TAILSCALE_CLIENT_SECRET`. Add:

```bash
# --- Tailscale VPS Host (for CI/CD deploy) ---
TAILSCALE_VPS_HOSTNAME="vps-k8s"
```

### 7. `wiki/concepts/tailscale.md` -- Expand CI/CD section

Replace the existing CI/CD Integration subsection with an expanded section covering:
- End-to-end flow: Git Push → Tailscale → Flux → Cluster
- Architecture table (runner, VPS host, Operator -- separate identities)
- `tailscale/github-action@v3` usage example
- Required ACLs (`tag:ci-runner → tag:vps-k8s:6443`)
- Why not webhook receivers
- Separate OAuth clients rationale
- Cross-reference to `wiki/concepts/tailscale-vps-strategy.md` for full VPS-side details

### 8. `README.md` -- Add CI/CD auto-deploy section

After the "GitOps with Flux CD" section, add:

```markdown
## CI/CD Auto-Deploy

Pushes to `main`/`master` trigger automated Flux reconciliation via a GitHub Actions
runner connected to the VPS through Tailscale.

### How It Works

1. You push to `main` → the [IaC Security Pipeline](.github/workflows/IaC.yml) runs.
2. Security gates pass (lint, secrets, misconfig, policy).
3. The deploy job connects the runner to the tailnet with `tag:ci-runner`.
4. Flux is told to immediately reconcile `infrastructure`, then `apps`.
5. The job waits for both Kustomizations to report `Ready`.
6. A smoke test prints pod status and Flux resource health.

### One-Time Setup

See these guides for the initial configuration:

- **[VPS Tailscale Setup](docs/vps-tailscale-setup.md)** -- Install Tailscale on the VPS host,
  get its Tailscale IP, and generate a CI kubeconfig.
- **[CI Deploy Secrets](docs/ci-deploy-secrets.md)** -- Create the Tailscale OAuth client for CI,
  encode the kubeconfig, and configure GitHub Environment secrets.

### Manual Trigger

You can still trigger reconciliation locally:
```bash
make sync
```
```

---

## Implementation Order

| Step | File | Action | Runtime Impact | Notes |
|------|------|--------|----------------|-------|
| 1 | `docs/vps-tailscale-setup.md` | Create | None (docs only) | One-time VPS host setup + firewall + coexistence check |
| 2 | `docs/ci-deploy-secrets.md` | Create | None (docs only) | Full chain: OAuth → ACL → SA → kubeconfig → GitHub secrets |
| 3 | `infrastructure/namespaces/ci-rbac.yaml` | Create | None (RBAC manifest) | `ci-deployer` SA with least-privilege ClusterRole |
| 4 | `kind/cluster.yaml` | Add certSANs | None (used on next rebuild) | Tailscale IP + MagicDNS in cert SANs |
| 5 | `config.env.example` | Add Tailscale + VPS vars | None (example config) | Operator creds + VPS hostname |
| 6 | `config.env` | Add `TAILSCALE_VPS_HOSTNAME` | None (env var) | |
| 7 | `wiki/concepts/tailscale.md` | Expand CI/CD section | None (wiki) | Cross-ref to tailscale-vps-strategy.md |
| 8 | `README.md` | Add auto-deploy section | None (docs) | Links to docs/ guides |
| 9 | `.github/workflows/IaC.yml` | Replace stub deploy job | **Activates auto-deploy** | |
| 10 | **Tailscale Admin Console** | Create OAuth client + ACLs | Enables connectivity | `tag:ci-runner` OAuth, ACL rule |
| 11 | **GitHub Settings** | Add Environment secrets | Enables connectivity | `TS_OAUTH_CLIENT_ID`, `TS_OAUTH_SECRET`, `KUBECONFIG` |
| 12 | **VPS** | Tailscale install + firewall + kubeconfig gen | Enables connectivity | Per docs steps 1-2 |
| 13 | **VPS** | Apply `ci-rbac.yaml` + generate SA kubeconfig | Enables least-privilege CI | `kubectl apply -f infrastructure/namespaces/ci-rbac.yaml` |

---

## Verification

| Check | Command | Expected |
|-------|---------|----------|
| YAML lint | `yamllint .github/workflows/IaC.yml` | No errors |
| Secret leak | `gitleaks detect --source .` | No findings in new files |
| Pre-commit | `pre-commit run --all-files` | All hooks pass |
| Workflow syntax | Push to branch → GitHub validates | No errors |

---

## What This Plan Does NOT Do

- **Does not change `setup.sh`** -- cluster creation and Flux bootstrap stay as-is on the VPS.
- **Does not change any Flux CRDs** -- `infrastructure.yaml` and `apps.yaml` stay as-is.
- **Does not change Tailscale Operator setup** -- service exposure (Headlamp, RabbitMQ, OpenBao) is untouched.
- **Does not implement webhook receivers** -- requires public URL, conflicts with private Tailscale architecture.
- **Does not configure the VPS** -- VPS-side Tailscale installation, firewall, and kubeconfig generation are documented (steps 1-2, 10-13), not automated.
- **Does not duplicate the VPS strategy wiki** -- `docs/vps-tailscale-setup.md` and `docs/ci-deploy-secrets.md` are actionable guides; `wiki/concepts/tailscale-vps-strategy.md` is the deep reference with troubleshooting, security model, and trade-off analysis.

---

**Summary:** 3 new files, 6 modified files, 0 deleted files. Core logic is ~40 lines of YAML replacing a 5-line stub. All existing infrastructure unchanged.

## Key Design Decisions (from Wiki Research)

| Decision | Rationale |
|----------|-----------|
| **Auth key for VPS host, OAuth for CI runner** | Persistent server vs. ephemeral CI — different identity models |
| **Separate OAuth clients (Operator vs CI)** | Credential blast radius isolation; independent rotation |
| **`insecure-skip-tls-verify` now, `certSANs` on rebuild** | Pragmatic: WireGuard provides transport security; fix TLS properly on next cluster recreate |
| **`ci-deployer` ServiceAccount (not cluster-admin)** | Least privilege — CI can only reconcile Flux, not delete resources |
| **VPS firewall: 6443 restricted to `100.64.0.0/10`** | Defense-in-depth below Tailscale ACLs — blocks non-Tailscale traffic at host level |
| **Six-layer security model** documented in wiki | Tailscale identity → ACLs → firewall → TLS → RBAC → GitHub approval |
