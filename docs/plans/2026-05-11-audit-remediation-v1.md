# Implementation Plan: Audit Remediation (Ordered by Severity)

## Objective

Address all confirmed findings from the `project-analysis-kind.md` audit validation, ordered from HIGH to LOW severity, to close security gaps, harden operations, and bring documentation in line with reality.

---

## HIGH Severity (4 findings)

- [x] **H1 -- Enable TLS on OpenBao** (`infrastructure/openbao/values.yaml:7-8`)

  Replace `global.tlsDisable: true` with self-signed certificate configuration. Generate a CA cert and server cert via a Kubernetes Secret or cert-manager. Update the HelmRelease values to reference the TLS secret. This closes the single largest security gap where all secrets traverse HTTP in cleartext. Minimal effort -- self-signed cert suffices for a lab.

  Rationale: Every service reading from OpenBao currently sends secrets over cleartext. TLS is the foundational fix.

- [x] **H2 -- Replace Headlamp cluster-admin with read-only ClusterRole** (`apps/headlamp/headlamp-admin.yaml:13-14`)

  Create a new ClusterRole scoped to `get/list/watch` on common resources (pods, services, deployments, configmaps, namespaces, events, nodes). Update the ClusterRoleBinding to reference the new restricted role instead of `cluster-admin`. Remove the old binding.

  Rationale: A web UI should never hold cluster-admin. Read-only access covers Headlamp's dashboard functionality without destructive potential.

- [x] **H3 -- Remove static Headlamp ServiceAccount token Secret** (`apps/headlamp/headlamp.yaml:92-99`)

  Delete the long-lived `kubernetes.io/service-account-token` Secret. Update README instructions to use `kubectl create token headlamp-admin -n kube-system` for login. A static token never expires and survives restarts -- a time-bound token generated on demand is the correct pattern.

  Rationale: Long-lived tokens violate token lifecycle management and are a persistence risk.

- [x] **H4 -- Scope serve-watcher RBAC to specific pods by label** (`tailscale/serve-watcher.yaml:29-31`)

  Narrowed the `pods/exec` Role from all pods in the `tailscale` namespace to only proxy pods matching a specific label selector (e.g., `tailscale.com/proxy: "true"`). Alternatively, replace `pods/exec` with a dedicated controller approach. At minimum, add a label selector to constrain exec access.

  Rationale: `pods/exec` on every pod in the namespace grants shell access to unintended targets if any other pod lands there.

---

## DONE (was MEDIUM Severity)

- [x] **M3 -- Fix serve-watcher `automountServiceAccountToken`** (`tailscale/serve-watcher.yaml:78-79`)

  Change `automountServiceAccountToken` from `false` to `true`. The watcher's container runs `kubectl exec` commands which require API authentication. With the token disabled, `kubectl exec` calls will fail. This is a broken configuration, not just a hardening gap.

  Rationale: This is a functional bug -- the watcher cannot fulfill its purpose without a token. Prioritized above other MEDIUM items for this reason.

- [x] **M8 -- Add `healthChecks` to Flux Kustomizations** (`clusters/kind/infrastructure.yaml`, `clusters/kind/apps.yaml`)

  Add `healthChecks` blocks to both Kustomization resources referencing key deployments (OpenBao, RabbitMQ, Headlamp, demo app). This enables Flux to report Ready only when pods are healthy, not just when manifests are applied. Without healthChecks, Flux silently accepts crash-looping deployments.

  Rationale: Observability gap -- Flux currently has no visibility into whether reconciled resources are actually healthy.

- [x] **M7 -- Enable OpenBao liveness probe** (`infrastructure/openbao/values.yaml:47-48`)

  Change `livenessProbe.enabled` from `false` to `true`. Use the same health endpoint as the readiness probe: `/v1/sys/health?standbyok=true`. Set appropriate thresholds (initialDelaySeconds: 60, periodSeconds: 10) to avoid premature restarts during unseal operations.

  Rationale: A hung OpenBao process will never be restarted without a liveness probe, leading to silent failure.

- [x] **M5 -- Pin Tailscale operator to a release tag** (`tailscale/install-operator.sh:29`, `setup.sh:80`)

  Replace the `main` branch URL with a pinned release tag (e.g., `v1.80.0` or whatever the current stable tag is). Apply the same change in both `install-operator.sh` and `setup.sh`. This eliminates the supply chain risk of running unreleased code from HEAD.

  Rationale: `main` branch deployments can introduce breaking changes or vulnerabilities without warning.

- [x] **M6 -- Move Istio to Flux HelmRelease** (`setup.sh:16`)

  Replace the imperative `istioctl install` with a Flux `HelmRelease` resource for the Istio base/istiod chart. This brings the service mesh under GitOps coverage so drift is auto-corrected. Place the HelmRelease in `infrastructure/istio/` with a dependency on namespaces.

  Rationale: The only remaining imperative install in the cluster -- everything else is declarative.

- [x] **M4 -- Change Kyverno `require-labels` to `Enforce` and label all deployments** (`policies/require-labels.yaml:13`)

  Change `validationFailureAction` from `Audit` to `Enforce`. Add required labels (`app`, `env`, `owner`) to all existing deployments: RabbitMQ, Headlamp, demo nginx, serve-watcher. Verify no unlabeled resources exist before flipping the switch.

  Rationale: An audit-only policy provides no enforcement value. Labels enable resource identification and cost tracking.

- [x] **M2 -- Integrate or remove orphaned `ci-rbac.yaml`** (`infrastructure/namespaces/kustomization.yaml`)

  Either add `ci-rbac.yaml` to `infrastructure/namespaces/kustomization.yaml` resources list (if CI/CD RBAC is needed) or delete the file entirely. The current orphaned state is dead code that causes confusion.

  Rationale: Dead code violates the design principle of keeping the codebase clean and intentional.

- [x] **M1 -- Add PVC for RabbitMQ or document ephemeral design explicitly** (`apps/rabbitmq/core/deployment.yaml:76-77`)

  Option A: Add a PersistentVolumeClaim and replace `emptyDir` with the PVC for message durability. Option B: Add a comment in the deployment YAML explicitly stating that `emptyDir` is intentional for a lab environment and messages are not durable. The current state is correct for a lab but undocumented.

  Rationale: Undocumented design decisions lead to incorrect assumptions. A comment costs nothing and prevents future confusion.

---

## LOW Severity (3 findings)

- [x] **L2 -- Substitute `certSANs` placeholders in `setup.sh`** (`kind/cluster.yaml:18-19`)

  Add a `sed` substitution in `setup.sh` that replaces `TAILSCALE_VPS_IP_PLACEHOLDER` and `TAILSCALE_VPS_HOSTNAME_PLACEHOLDER` with values from `config.env` (`TAILSCALE_VPS_IP` and `TAILSCALE_VPS_HOSTNAME`) before `kind create cluster`. Wrap in a conditional so it only runs when those variables are set.

  Rationale: Placeholder values in certSANs produce an invalid API server certificate for remote access.

- [x] **L1 -- Remove dead `bases/networkpolicy/` or reference it from overlays**

  Either delete `bases/networkpolicy/default-deny-ingress.yaml` (since every namespace has its own local copy) or refactor all namespace overlays to reference the base via Kustomize `resources` or `patchesStrategicMerge`. The current state has 4 identical copies of the same 8-line file plus an unused base.

  Rationale: DRY violation -- same NetworkPolicy duplicated in 4 namespaces when a single base could serve all.

- [x] **L3 -- Deduplicate `scripts/` and `scripts/secret-purge-tools/`**

  Remove the duplicate `auto-purge-secret.sh` and `purge-config.example.toml` from either `scripts/` or `scripts/secret-purge-tools/`. Keep one canonical location. Update any references (Makefile targets, documentation) to point to the single source.

  Rationale: Byte-identical files in two locations create a maintenance burden and risk divergence.

---

## INFORMATIONAL / False Negatives (3 items)

- [x] **CI-Gap -- Create CI pipeline definition**

  Create `.github/workflows/IaC.yml` with jobs for: (1) security scanning via `scripts/security-scan.sh`, (2) Kustomize build validation, (3) Flux reconciliation trigger on success. Use the Tailscale GitHub Action to connect the runner to the VPS. Wire in the `ci-rbac.yaml` ServiceAccount for authenticated Flux operations.

  Rationale: All scan tooling is professionally configured but requires manual invocation. A CI pipeline closes the automation gap.

- [x] **README -- Fix documentation inaccuracies** (`README.md:57-58, 128`)

  Either remove references to the non-existent `.github/workflows/IaC.yml` and Kustomize `images` patches, or replace them with accurate descriptions of what exists. If `images` patches are intended, create them. If the CI pipeline is planned, note it as "coming soon" rather than documenting it as present.

  Rationale: Documentation that describes non-existent features misleads users and erodes trust.

- [x] **mTLS -- Enable STRICT mTLS in Istio** (`istio/istio-operator.yaml`)

  Add `meshConfig` to the IstioOperator with `enableAutoMtls: true` and a `PeerAuthentication` resource setting `mode: STRICT` in the `istio-system` namespace. This enforces mutual TLS between all sidecar-injected services, closing the gap where internal traffic can fall back to plaintext.

  Rationale: The audit summary correctly identifies "TLS everywhere is broken" as a central theme. mTLS enforcement between services is the complementary fix to H1 (OpenBao TLS) and completes the encryption story.

---

## Verification Criteria

- [ ] OpenBao serves over HTTPS with valid (self-signed) certificate on port 8200
- [ ] Headlamp dashboard functions with read-only ClusterRole (no delete/edit/create access)
- [ ] Headlamp token generation works via `kubectl create token` (no static secret)
- [ ] serve-watcher `kubectl exec` calls succeed with `automountServiceAccountToken: true`
- [ ] serve-watcher RBAC scoped to specific proxy-only pods
- [ ] Flux reports health status for all managed resources (not just apply status)
- [ ] OpenBao liveness probe restarts hung processes
- [ ] Tailscale operator installed from pinned release tag
- [ ] Istio managed via Flux HelmRelease (no `istioctl` needed)
- [ ] All deployments carry `app`, `env`, `owner` labels and Kyverno enforces this
- [ ] `ci-rbac.yaml` either deployed or removed
- [ ] RabbitMQ storage decision explicitly documented in YAML
- [ ] All scans pass without regression after changes
- [ ] README accurately reflects what exists in the repository

## Risk Assessment

| Risk | Severity | Mitigation |
|---|---|---|
| OpenBao TLS cert generation may break existing secret readers | HIGH | Test in isolated branch first; document new CA trust requirements |
| Headlamp read-only may break UI features requiring write access | MEDIUM | Audit Headlamp's actual API calls; expand ClusterRole only if needed |
| Istio HelmRelease migration may conflict with existing istioctl install | MEDIUM | Uninstall istioctl-managed control plane before Flux takes over |
| Kyverno Enforce on labels may block existing deployments | LOW | Add labels before flipping validationFailureAction |
| mTLS STRICT may break non-sidecar services (RabbitMQ, OpenBao) | LOW | Apply only to `demo` namespace first; exclude non-mesh namespaces |
