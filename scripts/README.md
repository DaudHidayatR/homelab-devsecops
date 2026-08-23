# Homelab command scripts

```text
scripts/
├── homelab
├── commands/
│   ├── cluster.sh
│   ├── openbao.sh
│   ├── tailscale.sh
│   ├── security.sh
├── lib/
│   ├── common.sh
│   ├── kubernetes.sh
│   ├── flux.sh
│   ├── cluster.sh
│   ├── openbao.sh
│   ├── tailscale.sh
│   └── scanners/
│       ├── common.sh
│       ├── sca.sh
│       ├── sbom.sh
│       ├── secrets.sh
│       ├── iac.sh
│       └── image.sh
└── README.md
```

`scripts/homelab` is the only public entrypoint. Each file under `commands/` owns one command domain. Reusable primitives live under `lib/`; scanner implementations are split by evidence type under `lib/scanners/`.

## Command map

| Command | Purpose |
|---|---|
| `scripts/homelab cluster up` | Create/update the kind cluster and bootstrap Flux |
| `scripts/homelab cluster down` | Back up Tailscale identity and destroy the cluster |
| `scripts/homelab cluster recover <backup>` | Rebuild while restoring Tailscale identity |
| `scripts/homelab cluster info` | Print access endpoints |
| `scripts/homelab openbao bootstrap` | Initialize/unseal OpenBao and configure engines/auth/policies |
| `scripts/homelab openbao policies` | Reconcile OpenBao policy files and principal mappings |
| `scripts/homelab openbao status` | Show OpenBao readiness, seal, policy, and backup state |
| `scripts/homelab openbao create-user` | Create/update a userpass identity and optional SSH role |
| `scripts/homelab openbao create-approle <role> <policy>` | Create machine access with a wrapped SecretID |
| `scripts/homelab tailscale install` | Install the Kubernetes operator |
| `scripts/homelab tailscale reset` | Reset stale proxy identities |
| `scripts/homelab tailscale sign --sudo` | Sign proxy nodes for Tailnet Lock |
| `scripts/homelab tailscale check` | Check DNS, HTTPS, and Serve access |
| `scripts/homelab tailscale configure-serve` | Reconcile proxy Serve backends |
| `scripts/homelab tailscale restore <backup>` | Restore operator identity |
| `scripts/homelab security scan [scanner]` | Run all scanners or one named scanner |

Make targets remain convenience aliases. Sensitive OpenBao and Tailscale material stays under `.runtime-backups/` and outside Git.
# Tailscale Kubernetes Operator

This directory contains Tailscale operational helpers for the local kind DevSecOps lab. The operator exposes selected Kubernetes Services directly to your tailnet without traditional ingress controllers, cloud LoadBalancers, public IPs, or manual DNS/certificate management.

## Two-tier access architecture

| Tier | Annotation | Access level | Recommended use |
|---|---|---|---|
| **Private** | `tailscale.com/expose: "true"` | Tailnet only | Headlamp, OpenBao, internal dashboards |
| **Public** | `tailscale.com/funnel: "true"` | Internet-facing | Explicitly public demos/APIs only |

Both tiers use the same operator. Keep admin tools private by default. Promoting a service to public access should be a deliberate reviewable change.

## Primary setup flow

The preferred path is through the main lab setup entrypoint:

```bash
make up
```

When these values are present in `config.env`, `scripts/homelab cluster up` performs the Tailscale setup automatically:

```bash
TAILSCALE_CLIENT_ID="..."
TAILSCALE_CLIENT_SECRET="..."
```

Automated steps:

1. Create the `tailscale` namespace if needed.
2. Restore and validate any saved `tailscale/operator` identity before operator startup.
3. Create the optional `operator-oauth` Secret from configured OAuth credentials.
4. Install the Tailscale Kubernetes Operator when missing.
5. Annotate the main OpenBao Service for tailnet exposure.
6. Wait for operator-managed proxy pods.
7. Run `scripts/homelab tailscale configure-serve`, the single scheme-aware backend selector.

Use this primary path for normal first-time setup.

## Manual Tailscale install and Serve repair

Use this when Tailscale credentials were not present during `make up`, or when you are repairing only Tailscale access:

```bash
make tailscale
scripts/homelab tailscale configure-serve
scripts/homelab tailscale check
```

`make tailscale` runs `scripts/homelab tailscale install`. Treat it as an advanced/manual path, not the default `make up` path.

## Tailscale identity recovery during cluster rebuild

The Tailscale operator stores its authoritative device identity in Kubernetes Secret `tailscale/operator`. The backup form is `.runtime-backups/tailscale/<timestamp>/operator.json`. Losing it during a cluster rebuild can register a duplicate device such as `tailscale-operator-1`.

> **Tailscale only:** this procedure does not back up or restore OpenBao Raft data, its PVC, or secrets. Never pass an OpenBao snapshot or `.runtime-backups/openbao/` to `make recover`; see the OpenBao Raft procedure in the project [README](../README.md#openbao-integrated-storage-raft-recovery).

Use this only when the kind cluster must be destroyed or has already been lost; use `make redeploy` for normal changes. It requires a validated `operator.json` if no live cluster exists, plus working kind, kubectl, Python, repository configuration, and Flux prerequisites.

Ordered recovery:

1. Run `BACKUP_DIR=.runtime-backups/tailscale/<timestamp> make recover`.
2. With a live cluster, recovery validates and backs up live Secret `tailscale/operator`, deletes the cluster, and uses that fresh backup instead of the older supplied path.
3. Recovery creates a bare kind cluster, restores identity before operator startup, and bootstraps Flux and workloads. Missing or malformed identity aborts the operation.
4. If required, run `scripts/homelab tailscale sign --sudo`, then `scripts/homelab tailscale configure-serve`.
5. Verify the operator rollout and identity:
   ```bash
   kubectl rollout status deployment/operator -n tailscale --timeout=120s
   kubectl get secret operator -n tailscale
   scripts/homelab tailscale check
   ```

Success means the rollout and access check pass and the existing operator device identity remains in the Tailscale Admin Console without a new duplicate.

### Stale or deleted Tailscale devices

If Kubernetes proxy devices were deleted manually in the Tailscale Admin Console, reset stale Kubernetes identities and let proxies register fresh:

```bash
scripts/homelab tailscale reset
scripts/homelab tailscale sign --sudo
scripts/homelab tailscale configure-serve
scripts/homelab tailscale check
```

### Tailnet Lock

If Tailnet Lock is enabled, newly registered Kubernetes proxy nodes must be signed before DNS/connectivity is fully available:

```bash
make tailscale-sign
# or
scripts/homelab tailscale sign --sudo
```

## Verification commands

Check operator deployment:

```bash
kubectl get deployment operator -n tailscale
kubectl rollout status deployment/operator -n tailscale --timeout=120s
```

Check proxy pods:

```bash
kubectl get pods -n tailscale -l tailscale.com/managed=true
```

List exposed services:

```bash
kubectl get svc -A -o jsonpath='{range .items[?(@.metadata.annotations.tailscale\.com/expose=="true")]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}'
```

Run the project access check:

```bash
scripts/homelab tailscale check
```

Re-apply Serve config if proxy pods were recreated:

```bash
scripts/homelab tailscale configure-serve
```

## Expected URLs

Once proxy DNS and Serve are ready, admin UIs are available from devices allowed by your tailnet ACLs:

| Service | Tailnet URL pattern |
|---|---|
| Headlamp | `https://kube-system-headlamp.<tailnet>.ts.net` |
| OpenBao | `https://openbao-openbao.<tailnet>.ts.net/ui/` |

## Security notes

- Prefer private `tailscale.com/expose: "true"` for admin tools.
- Use public `tailscale.com/funnel: "true"` only for intentionally public services.
- Tailscale ACLs still govern which tailnet users can reach exposed services.
- Treat OAuth client secrets and the `tailscale/operator` identity Secret as sensitive.
- Do not run destructive reset scripts unless you understand whether you are preserving or intentionally replacing device identity.

## File map

| File | Purpose |
|---|---|
| `install-operator.sh` | Manual operator installation fallback |
| `restore-state.sh` | Restore saved Tailscale Kubernetes identity state |
| `reset-proxies.sh` | Remove stale proxy identity state so proxies can register fresh |
| `sign-proxies.sh` | Sign new proxy devices when Tailnet Lock is enabled |
| `check-access.sh` | Validate DNS, HTTPS, and Serve access expectations |
