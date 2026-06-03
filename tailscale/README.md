# Tailscale Kubernetes Operator

This directory contains Tailscale operational helpers for the local kind DevSecOps lab. The operator exposes selected Kubernetes Services directly to your tailnet without traditional ingress controllers, cloud LoadBalancers, public IPs, or manual DNS/certificate management.

## Two-tier access architecture

| Tier | Annotation | Access level | Recommended use |
|---|---|---|---|
| **Private** | `tailscale.com/expose: "true"` | Tailnet only | Headlamp, OpenBao, RabbitMQ admin, internal dashboards |
| **Public** | `tailscale.com/funnel: "true"` | Internet-facing | Explicitly public demos/APIs only |

Both tiers use the same operator. Keep admin tools private by default. Promoting a service to public access should be a deliberate reviewable change.

## Primary setup flow

The preferred path is through the main lab setup entrypoint:

```bash
make up
```

When these values are present in `config.env`, `setup.sh` performs the Tailscale setup automatically:

```bash
TAILSCALE_CLIENT_ID="..."
TAILSCALE_CLIENT_SECRET="..."
```

Automated steps:

1. Create the `tailscale` namespace if needed.
2. Create the `operator-oauth` Secret from the OAuth client credentials.
3. Preserve any existing `tailscale/operator` Secret identity before reinstall attempts.
4. Install the Tailscale Kubernetes Operator when missing.
5. Annotate the main OpenBao Service for tailnet exposure.
6. Wait for operator-managed proxy pods.
7. Run `scripts/configure-tailscale-serve.sh` to configure HTTPS Serve behavior.
8. Deploy `tailscale/serve-watcher.yaml` so Serve config is re-applied after proxy restarts.
9. Print final setup/access guidance.

Use this primary path for normal first-time setup.

## Manual fallback flow

Use this when Tailscale credentials were not present during `make up`, or when you are repairing only Tailscale access:

```bash
make tailscale
./scripts/configure-tailscale-serve.sh
./tailscale/check-access.sh
```

`make tailscale` runs `tailscale/install-operator.sh`. Treat it as an advanced/manual path, not the default `make up` path.

## Recovery and identity preservation

The Tailscale operator stores its device identity in the Kubernetes Secret:

```text
tailscale/operator
```

That Secret contains machine/profile identity material. If it is lost during a cluster rebuild, the operator can register as a new duplicate Tailscale device, often with a suffix such as `tailscale-operator-1`.

### Full cluster rebuild sequence

Prefer restoring identity before the operator starts in the rebuilt cluster:

```bash
make down
./tailscale/restore-state.sh latest
make up
./scripts/configure-tailscale-serve.sh
./tailscale/check-access.sh
```

If local backups exist, `setup.sh` also prints warnings when it detects that the `tailscale` namespace or `operator` Secret is missing.

### Stale or deleted Tailscale devices

If Kubernetes proxy devices were deleted manually in the Tailscale Admin Console, reset stale Kubernetes identities and let proxies register fresh:

```bash
./tailscale/reset-proxies.sh
./tailscale/sign-proxies.sh --sudo
./scripts/configure-tailscale-serve.sh
./tailscale/check-access.sh
```

### Tailnet Lock

If Tailnet Lock is enabled, newly registered Kubernetes proxy nodes must be signed before DNS/connectivity is fully available:

```bash
make tailscale-sign
# or
./tailscale/sign-proxies.sh --sudo
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
./tailscale/check-access.sh
```

Re-apply Serve config if proxy pods were recreated:

```bash
./scripts/configure-tailscale-serve.sh
```

## Expected URLs

Once proxy DNS and Serve are ready, admin UIs are available from devices allowed by your tailnet ACLs:

| Service | Tailnet URL pattern |
|---|---|
| Headlamp | `https://kube-system-headlamp.<tailnet>.ts.net` |
| RabbitMQ | `https://messaging-rabbitmq.<tailnet>.ts.net` |
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
| `serve-watcher.yaml` | Keeps Tailscale Serve configuration persistent across proxy restarts |
