# Plan: Fix Flux Integration After Networking Changes

**Date:** 2026-05-07
**Scope:** `infra/kind` repository — Flux CD GitOps migration and Tailscale networking fixes
**Objective:** Resolve drift between the networking fix commit (`126a88b`) and the uncommitted Flux migration, ensuring OpenBao, Headlamp, and fallback mode all work correctly.

---

## Background

Two streams of work are uncommitted in the working tree:

1. **Flux CD migration** (`wiki/log.md:2026-05-06`) — Added `clusters/kind/`, `infrastructure/`, moved OpenBao to `HelmRelease`, slimmed `setup.sh`, added Makefile targets.
2. **Networking fix** (`126a88b`) — Added `tailscale.com/serve: "true"` to OpenBao and RabbitMQ services, created `configure-tailscale-serve.sh` and `serve-watcher.yaml`.

These streams diverged. The networking fix modified `openbao/values.yaml` but **not** `infrastructure/openbao/values.yaml` (the file Flux consumes). Headlamp did not receive the `serve` annotation. The fallback `kubectl apply -k` path no longer deploys OpenBao because the Helm install block was removed from `setup.sh` and the root `kustomization.yaml` does not include `infrastructure/openbao/`.

---

## Issues Found

| # | Issue | Severity | File(s) |
|---|-------|----------|---------|
| 1 | OpenBao values out of sync — `tailscale.com/serve` missing in Flux-managed copy | **High** | `infrastructure/openbao/values.yaml` |
| 2 | Fallback mode (`kubectl apply -k`) does not deploy OpenBao | **High** | `setup.sh`, `kustomization.yaml` |
| 3 | Headlamp missing `tailscale.com/serve` — same HTTPS timeout risk as fixed for others | **Medium** | `headlamp/headlamp.yaml` |
| 4 | Orphaned namespace manifests — removed from kustomizations but files still exist | **Low** | `apps/demo/namespace.yaml`, `rabbitmq/namespace.yaml`, `openbao/namespace.yaml` |
| 5 | Root `kustomization.yaml` includes `infrastructure/namespaces/` but not `infrastructure/openbao/` | **Medium** | `kustomization.yaml` |

---

## Implementation Plan

### Phase 1 — Sync OpenBao Values for Tailscale Serve

- [ ] Task 1.1: Add `tailscale.com/serve: "true"` to `infrastructure/openbao/values.yaml`
  - Rationale: The Flux-managed `HelmRelease` reads values from `infrastructure/openbao/values.yaml` via ConfigMapGenerator. Without this annotation, the Tailscale operator will expose the service but not configure HTTPS serve, causing `ERR_CONNECTION_TIMED_OUT` from tailnet clients.
  - File: `infrastructure/openbao/values.yaml:22`
  - Add under `server.service.annotations`:
    ```yaml
    tailscale.com/serve: "true"
    ```

- [ ] Task 1.2: Update comment in `infrastructure/openbao/values.yaml` to clarify sync requirement
  - Rationale: Prevent future divergence when one file is edited and the other is forgotten.
  - File: `infrastructure/openbao/values.yaml:2-3`

### Phase 2 — Fix Fallback Mode

- [ ] Task 2.1: Add `infrastructure/openbao/` to root `kustomization.yaml` resources
  - Rationale: When `GITHUB_TOKEN` / `GITHUB_USER` are not set, `setup.sh` falls back to `kubectl apply -k "${SCRIPT_DIR}"`. The root kustomization must include `infrastructure/openbao/` so the `HelmRelease` and `HelmRepository` are applied directly via Kustomize (they are plain YAML; the Helm controller already runs inside the cluster even without Flux bootstrap).
  - File: `kustomization.yaml`
  - Add `- infrastructure/openbao/` under `resources:`

- [ ] Task 2.2: Verify `kubectl kustomize .` renders `HelmRelease` and `HelmRepository` correctly
  - Rationale: Ensure the root overlay produces valid YAML before any cluster testing.

### Phase 3 — Fix Headlamp Tailscale Serve

- [ ] Task 3.1: Add `tailscale.com/serve: "true"` to Headlamp Service annotations
  - Rationale: Headlamp is the only admin service (alongside OpenBao and RabbitMQ) that did not receive the `serve` annotation in the networking fix. This creates an inconsistent access experience and risks HTTPS timeouts.
  - File: `headlamp/headlamp.yaml:7`
  - Change to:
    ```yaml
    annotations:
      tailscale.com/expose: "true"
      tailscale.com/serve: "true"
    ```

### Phase 4 — Clean Up Orphaned Namespace Manifests

- [ ] Task 4.1: Delete `apps/demo/namespace.yaml`
  - Rationale: Namespaces now live in `infrastructure/namespaces/demo.yaml`. The old file is dead code.

- [ ] Task 4.2: Delete `rabbitmq/namespace.yaml`
  - Rationale: Same as above; `infrastructure/namespaces/messaging.yaml` is the source of truth.

- [ ] Task 4.3: Delete `openbao/namespace.yaml`
  - Rationale: Same as above; `infrastructure/namespaces/openbao.yaml` is the source of truth.

- [ ] Task 4.4: Verify no `namespace.yaml` remains in component directories
  - Rationale: Prevent confusion about which file defines the namespace.

### Phase 5 — Validation

- [ ] Task 5.1: Run `make validate-kustomize` and confirm all overlays pass
  - Rationale: Catch syntax errors in Kustomize manifests before cluster deployment.

- [ ] Task 5.2: Run `kubectl kustomize .` and inspect output for:
  - `HelmRelease` named `openbao` in namespace `openbao`
  - `HelmRepository` named `openbao` in namespace `flux-system`
  - OpenBao Service with `tailscale.com/serve: "true"` annotation
  - Headlamp Service with `tailscale.com/serve: "true"` annotation
  - No orphaned Namespace objects from component directories

- [ ] Task 5.3: Verify `setup.sh` fallback path
  - Rationale: Confirm that without `GITHUB_TOKEN`, the script applies all manifests including OpenBao via `kubectl apply -k`.
  - Steps: Temporarily unset `GITHUB_TOKEN` and run `bash -n setup.sh` + review the fallback branch logic.

- [ ] Task 5.4: (Optional live cluster) Run `make up` with `GITHUB_TOKEN` set
  - Rationale: Full end-to-end validation of Flux bootstrap + Tailscale serve on all three admin services.
  - Check: `flux get helmreleases` shows OpenBao `Ready=True`
  - Check: `kubectl get svc -n openbao openbao -o yaml` contains both `expose` and `serve` annotations
  - Check: `kubectl get svc -n kube-system headlamp -o yaml` contains both `expose` and `serve` annotations

---

## Verification Criteria

- [ ] `infrastructure/openbao/values.yaml` contains `tailscale.com/serve: "true"`
- [ ] Root `kustomization.yaml` includes `infrastructure/openbao/` in `resources`
- [ ] `headlamp/headlamp.yaml` Service contains `tailscale.com/serve: "true"`
- [ ] No `namespace.yaml` files remain in `apps/demo/`, `rabbitmq/`, or `openbao/`
- [ ] `make validate-kustomize` passes with zero errors for all 6 overlays
- [ ] `kubectl kustomize .` output includes `HelmRelease` and `HelmRepository` for OpenBao
- [ ] `bash -n setup.sh` passes syntax check

---

## Potential Risks and Mitigations

1. **Risk: Deleting old `namespace.yaml` files breaks a workflow that references them directly**
   - Mitigation: Search the repo for direct `kubectl apply -f` commands targeting these files. None exist in `setup.sh` or `Makefile`.

2. **Risk: Adding `infrastructure/openbao/` to root kustomization causes duplicate resource errors if Flux is already managing it**
   - Mitigation: This is only a concern in fallback mode. When Flux is active, `setup.sh` does not run `kubectl apply -k`. The root kustomization is applied via the `apps` Kustomization CRD, which sources from `./apps` — not the root. The root `kustomization.yaml` is only used by the fallback path.

3. **Risk: `tailscale.com/serve` on Headlamp may conflict with existing `tailscale.com/expose`**
   - Mitigation: OpenBao and RabbitMQ already use both annotations together successfully. The operator handles both; `expose` creates the proxy, `serve` configures HTTPS forwarding.

---

## Alternative Approaches

1. **Alternative: Keep old `namespace.yaml` files and add them back to component kustomizations**
   - Trade-off: Duplicates namespace definitions. `infrastructure/namespaces/` and component kustomizations would both create the same namespace. Kustomize tolerates this, but it violates DRY.
   - Rejected: The Flux migration intentionally centralized namespaces in `infrastructure/namespaces/`.

2. **Alternative: In fallback mode, keep the old imperative `helm upgrade --install` block in `setup.sh`**
   - Trade-off: Adds complexity back to `setup.sh`. The HelmRelease is already valid YAML that kubectl can apply; the helm-controller (part of Flux) must be running, but in fallback mode it won't be.
   - Rejected: In fallback mode without Flux, the Helm controller doesn't exist, so applying a `HelmRelease` CRD does nothing. A better fix is to ensure the user either uses Flux or documents that OpenBao requires manual Helm install in fallback mode. However, for consistency with the migration intent, adding `infrastructure/openbao/` to root kustomize at least applies the CRDs so they are ready when Flux is later bootstrapped.

---

## Assumptions

- The user intends to keep the Flux migration (uncommitted files) and commit them after fixes.
- The `tailscale.com/serve` annotation pattern from the networking fix is the desired state for all tailnet-exposed services.
- Live cluster validation (Task 5.4) is optional because the environment may not have an active cluster.
