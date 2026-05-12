# Tailscale Private Admin Access — Implementation Plan

## Objective

Establish secure, private web access to administration interfaces (Headlamp, OpenBao, RabbitMQ) via the Tailscale Kubernetes Operator, keeping all admin tools tailnet-private. Lay the groundwork for a future public tier (portfolio, public demos) using the same operator with a single annotation change.

## Context

- The cluster is a `kind` lab running on a VM/VPS.
- Admin services currently require `kubectl port-forward` or SSH tunneling.
- The repository already uses Kustomize for GitOps-style management.
- Tailscale concepts are documented in `wiki/concepts/tailscale.md`.
- The design philosophy follows `wiki/concepts/software-design-principles.md` (KISS, YAGNI, DRY).

## Two-Tier Architecture

| Tier | Annotation | Access Level | Use Case |
|------|-----------|--------------|----------|
| **Private** | `tailscale.com/expose: "true"` | Tailnet only | Headlamp, OpenBao, RabbitMQ admin |
| **Public** | `tailscale.com/funnel: "true"` | Internet (anyone) | Portfolio, public APIs, demo sites |

Both tiers use the **same** Tailscale Kubernetes Operator. Upgrading from private to public is a one-line annotation change with no infrastructure modifications.

---

## Implementation Plan

### Phase 1: Install Tailscale Kubernetes Operator

- [ ] Apply the official Tailscale Kubernetes Operator manifest to the cluster.
  - **Rationale:** This single component handles all tailnet exposure for Services. No per-service sidecars or manual CLI commands are needed.
  - **Command:** `kubectl apply -f https://github.com/tailscale/tailscale/releases/latest/download/tailscale-operator.yaml`
  - **Note:** Requires a Tailscale OAuth client or auth key configured as a Kubernetes secret. The operator README covers this.

### Phase 2: Configure Private Admin Access

- [ ] Annotate `headlamp/headlamp.yaml` Service with `tailscale.com/expose: "true"`.
  - **Rationale:** Headlamp is the Kubernetes web UI. Keeping it tailnet-private ensures only authorized devices on the tailnet can manage the cluster.
  - **Change:** Add `metadata.annotations.tailscale.com/expose: "true"` to `headlamp/headlamp.yaml:3-5`.

- [ ] Annotate OpenBao Service for tailnet exposure.
  - **Rationale:** OpenBao manages secrets and sensitive configuration. It must never be publicly exposed.
  - **Approach:** OpenBao is deployed via Helm (`openbao/values.yaml`). Add the annotation through Helm values or patch the Service post-deployment.
  - **Helm values path:** `server.service.annotations.tailscale.com/expose: "true"`
  - **Fallback:** `kubectl annotate svc openbao -n openbao tailscale.com/expose=true`

- [ ] Annotate RabbitMQ Service for tailnet exposure.
  - **Rationale:** RabbitMQ management UI (`15672`) contains queue data and message payloads. Admin access should be tailnet-restricted.
  - **Change:** Add `metadata.annotations.tailscale.com/expose: "true"` to `rabbitmq/core/service.yaml` (or a dedicated management Service if split).

### Phase 3: Update Kustomize / GitOps Manifests

- [ ] Verify `headlamp/kustomization.yaml` includes the annotated Service resource.
  - **Rationale:** The annotation is added to the existing Service; no new file is needed. Confirm the resource list references `headlamp.yaml`.

- [ ] Verify `rabbitmq/kustomization.yaml` includes the annotated Service resource.
  - **Rationale:** Ensure the Service with the new annotation is part of the Kustomize build output.

- [ ] Update `openbao/kustomization.yaml` or document the Helm values change.
  - **Rationale:** OpenBao is Helm-based, not raw Kustomize. The annotation may be applied via values file or a post-render patch.

### Phase 4: Documentation and Wiki Updates

- [ ] Update `wiki/concepts/tailscale.md` with the two-tier pattern (`expose` vs `funnel`).
  - **Rationale:** The wiki is the source of truth. Documenting the pattern prevents future confusion about which annotation to use.

- [ ] Add a "Tailscale Access" section to `README.md` explaining how to reach admin UIs after deployment.
  - **Rationale:** New users cloning the repo need to know how to access Headlamp/OpenBao without reading through all manifests.

- [ ] Record the implementation in `wiki/log.md`.
  - **Rationale:** `AGENT.md` mandates append-only history tracking.

### Phase 5: Future Public Tier (Deferred)

- [ ] Document the `funnel` upgrade path for public services.
  - **Rationale:** When the user later deploys a portfolio or public demo, the pattern is already established: change `expose` to `funnel`.
  - **Example:** `tailscale.com/funnel: "true"` on a portfolio Service.

---

## Verification Criteria

- [ ] `kubectl get svc -n kube-system headlamp -o jsonpath='{.metadata.annotations.tailscale\.com/expose}'` returns `"true"`.
- [ ] `kubectl get svc -n openbao openbao -o jsonpath='{.metadata.annotations.tailscale\.com/expose}'` returns `"true"`.
- [ ] `kubectl get svc -n messaging rabbitmq -o jsonpath='{.metadata.annotations.tailscale\.com/expose}'` returns `"true"`.
- [ ] Tailscale proxy pods are created in each namespace (`kubectl get pods -n <ns> -l app=tailscale-proxy`).
- [ ] Services are resolvable from a device on the tailnet at `https://<service>-<namespace>.<tailnet>.ts.net`.
- [ ] `kustomize build headlamp/` renders without errors.
- [ ] `kustomize build rabbitmq/` renders without errors.

## Potential Risks and Mitigations

1. **Tailscale Operator Requires Auth Credentials**
   **Risk:** The operator needs an OAuth client or auth key to join the tailnet. Without it, the operator pod will fail.
   **Mitigation:** Follow the official Tailscale operator setup guide to create an OAuth client with `devices` write scope and store it as the `operator-oauth` secret before applying the manifest.

2. **OpenBao Helm Values Override Conflicts**
   **Risk:** Adding annotations via Helm values may conflict with existing `server.service` overrides in `openbao/values.yaml`.
   **Mitigation:** Review the existing values file for existing `service` blocks and merge the annotation map carefully.

3. **Hostname Collisions in Tailnet**
   **Risk:** If multiple clusters or Services share the same name, Tailscale DNS hostnames may collide.
   **Mitigation:** Tailscale automatically suffixes with namespace (`service-namespace.tailnet.ts.net`). For multiple clusters, use different tailnets or override hostnames via `tailscale.com/hostname` annotation.

4. **Kind Cluster Networking with Tailscale Proxy**
   **Risk:** In Docker-based `kind` clusters, Tailscale proxy pods may have MTU or NAT issues.
   **Mitigation:** Tailscale proxies use userspace networking by default inside containers. This is well-supported, but verify connectivity after deployment.

## Alternative Approaches

1. **VM-Level `tailscale serve` / `tailscale funnel`**
   - **Description:** Run `tailscale serve` on the VM for each `kubectl port-forward` session.
   - **Trade-offs:** Simple for one-off debugging, but manual, non-declarative, and does not scale. Violates DRY and KISS for a multi-service setup.

2. **Istio Ingress Gateway + Tailscale on VM**
   - **Description:** Switch Istio to a profile with an ingress gateway, expose the gateway via `NodePort`, then use Tailscale on the VM to reach it.
   - **Trade-offs:** Adds significant complexity (Gateway, VirtualService, certificates). The `minimal` profile was chosen explicitly to avoid this (`README.md:89`).

3. **Cloud LoadBalancer + Public Ingress**
   - **Description:** Use a cloud provider LoadBalancer and a public domain with cert-manager.
   - **Trade-offs:** Not applicable to a VM/VPS `kind` cluster. Requires public IP, DNS records, and certificate management. Overkill for a private lab.

## Assumptions

- A Tailscale account and tailnet already exist.
- The VM/VPS is already on the tailnet (for admin SSH), but this is separate from cluster-level exposure.
- The user will create the Tailscale OAuth client / auth key out-of-band.
- `kubectl` and `helm` are configured and working on the VM.
