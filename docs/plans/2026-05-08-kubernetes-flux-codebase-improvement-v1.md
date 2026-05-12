# Plan: Kubernetes and Flux Codebase Improvement

**Date:** 2026-05-08  
**Scope:** `infra/kind` repository — Flux CD reconciliation paths, Kustomize overlays, setup flow, OpenBao Helm values, GitOps secret direction, and validation gates.  
**Objective:** Improve the codebase based on the wiki analysis in `wiki/concepts/kubernetes-flux-infrastructure-mapping.md`, while preserving the lab's KISS/YAGNI posture.

---

## Source Basis

This plan is derived from the following wiki and repository references:

- `wiki/concepts/kubernetes-flux-infrastructure-mapping.md`
- `wiki/concepts/flux.md`
- `wiki/concepts/flux-implementation-plan.md`
- `wiki/concepts/kubernetes-hardening.md`
- `wiki/concepts/kubernetes.md`
- `clusters/kind/infrastructure.yaml`
- `clusters/kind/apps.yaml`
- `infrastructure/kustomization.yaml`
- `infrastructure/openbao/kustomization.yaml`
- `infrastructure/openbao/helmrelease.yaml`
- `kustomization.yaml`
- `setup.sh`
- `Makefile`

---

## Current State Summary

The repository has a good GitOps foundation:

- `clusters/kind/` is the Flux bootstrap entry point.
- `clusters/kind/infrastructure.yaml` reconciles `./infrastructure`.
- `clusters/kind/apps.yaml` reconciles `./apps` and depends on `infrastructure`.
- OpenBao has been moved to Flux-managed `HelmRepository` and `HelmRelease` resources.
- The root Kustomize overlay injects shared namespace labels and security-context hardening.
- NetworkPolicies and Pod Security Admission labels are present.
- Security scanning and policy checks exist through local scripts and GitHub Actions.

The main improvement theme is alignment: Flux paths, manual fallback paths, local validation, and documented repository structure should all render the same intended state.

---

## Issues to Fix

| # | Issue | Severity | Primary Files | Summary |
|---|---|---|---|---|
| 1 | `apps/` Flux path is not locally buildable | **High** | `clusters/kind/apps.yaml`, `apps/`, `Makefile` | `kubectl kustomize apps` fails because `apps/` has no root `kustomization.yaml`. |
| 2 | Flux app scope and root fallback scope diverge | **High** | `clusters/kind/apps.yaml`, `kustomization.yaml` | Manual fallback applies root overlay; Flux applies `infrastructure/` and `apps/` separately. |
| 3 | OpenBao values ConfigMap name may be unstable | **High** | `infrastructure/openbao/kustomization.yaml`, `infrastructure/openbao/helmrelease.yaml` | `configMapGenerator` can produce a hash-suffixed name while `HelmRelease` references `openbao-values`. |
| 4 | RabbitMQ secret creation can fail on fresh cluster | **High** | `setup.sh`, `infrastructure/namespaces/messaging.yaml` | `setup.sh` creates the secret before the namespace is guaranteed to exist. |
| 5 | Hardening patches may not apply under Flux app path | **Medium** | `kustomization.yaml`, `apps/`, workload manifests | Security contexts are injected at root overlay; Flux app path may bypass root patches. |
| 6 | Demo namespace does not explicitly enforce restricted PSA | **Medium** | `infrastructure/namespaces/demo.yaml`, `bases/namespace/common-labels.yaml` | Root patch adds audit/warn but not enforce for `demo`. |
| 7 | Headlamp uses broad `cluster-admin` | **Medium** | `headlamp/headlamp-admin.yaml` | Acceptable for lab convenience, but should be marked and later narrowed. |
| 8 | Secret management is not fully GitOps-native | **Medium** | `setup.sh`, future secret manifests | Runtime generation avoids Git leaks, but Flux cannot reconcile secret desired state. |
| 9 | Validation targets do not test exact Flux paths | **Medium** | `Makefile`, `.github/workflows/IaC.yml` | `apps/demo` is validated, but the actual Flux `./apps` path is not. |
| 10 | Documentation can drift from real layout | **Low** | `README.md`, wiki pages | Project structure docs should reflect the chosen final mapping. |

---

## Design Constraints

1. **Keep the lab simple.** Do not introduce production-only systems unless they directly fix a present issue.
2. **Avoid manifest duplication.** Prefer Kustomize aggregation and shared bases over copied YAML.
3. **Make Flux and manual fallback predictable.** If both exist, document and validate both.
4. **Keep secrets out of Git.** If secrets become declarative, use encryption or an external secret controller.
5. **Improve in small phases.** Each phase must have independent validation.

---

## Target End State

After the plan is complete:

- `kubectl kustomize apps` succeeds.
- `kubectl kustomize infrastructure` succeeds.
- `kubectl kustomize .` succeeds.
- Flux and fallback rendering are intentionally aligned or explicitly documented as separate modes.
- OpenBao `HelmRelease` can reliably find `openbao-values`.
- `setup.sh` works on a fresh cluster without namespace-ordering failures.
- Security-context hardening is applied consistently in the Flux-managed path.
- CI and `make validate-kustomize` validate the same paths Flux uses.
- README and wiki match the real codebase structure.

---

## Implementation Plan

### Phase 0 — Baseline Inventory and Safety Check

**Goal:** Confirm the current state before changing manifests.

- [ ] Task 0.1: Run `git status --short` and record modified/untracked files.
  - Rationale: Avoid mixing this improvement work with unrelated local changes.

- [ ] Task 0.2: Run current validation commands.
  - Commands to run manually or through Make:
    - `kubectl kustomize .`
    - `kubectl kustomize infrastructure`
    - `kubectl kustomize apps`
    - `make validate-kustomize`
  - Expected current result: `kubectl kustomize apps` fails until Phase 1 is implemented.

- [ ] Task 0.3: Capture current rendered root output for comparison.
  - Rationale: The root overlay currently shows the full intended lab state. Later phases should not accidentally drop workloads.

**Exit Criteria:** Current failures are understood and documented before edits begin.

---

### Phase 1 — Make the Flux `apps/` Path Buildable

**Goal:** Make `clusters/kind/apps.yaml` point to a valid, explicit Kustomize overlay.

- [ ] Task 1.1: Add `apps/kustomization.yaml`.
  - It should aggregate the application-layer resources that Flux should manage.
  - Minimum inclusion: `demo/`.
  - Decision required: either move RabbitMQ and Headlamp under `apps/`, or include them through a dedicated aggregate overlay if Kustomize load restrictions allow it.

- [ ] Task 1.2: Choose one app-layer mapping.

  **Option A — Minimal and safest:**
  - Keep `apps/kustomization.yaml` limited to `demo/`.
  - Move RabbitMQ, Headlamp, and OpenBao NetworkPolicy handling to an explicit infrastructure or platform layer.
  - Update README to avoid claiming `apps` manages RabbitMQ/Headlamp.

  **Option B — Broader app aggregate:**
  - Make `apps/kustomization.yaml` include `demo/`, RabbitMQ, Headlamp, and app-facing OpenBao NetworkPolicies.
  - This may require moving directories under `apps/` to avoid Kustomize parent-directory load restriction issues.

  **Recommended:** Option A first. It is smaller, safer, and keeps the first fix focused on Flux path validity.

- [ ] Task 1.3: Update `clusters/kind/apps.yaml` only if the app aggregate path changes.
  - Current path `./apps` can remain if `apps/kustomization.yaml` is added.

- [ ] Task 1.4: Validate `kubectl kustomize apps`.

**Exit Criteria:** `kubectl kustomize apps` succeeds and renders the intended Flux app layer.

---

### Phase 2 — Decide and Align Flux Scope vs Manual Fallback Scope

**Goal:** Remove ambiguity between Flux reconciliation and `kubectl apply -k` fallback.

- [ ] Task 2.1: Decide whether root `kustomization.yaml` is a local aggregate only or a Flux aggregate.

  **Recommended decision:** Keep root `kustomization.yaml` as a local/fallback aggregate and keep Flux split into `infrastructure` and `apps` layers.

- [ ] Task 2.2: Document the decision in `README.md`.
  - State that Flux reconciles `infrastructure/` then `apps/`.
  - State that root `kustomization.yaml` exists for local validation and fallback.
  - State whether the fallback is fully equivalent or intentionally limited.

- [ ] Task 2.3: Ensure no resource is only available in the root overlay unless that is intentional.
  - If RabbitMQ and Headlamp are expected under Flux, they must be reachable from a Flux `Kustomization` path.
  - If they are local-only for now, document that clearly.

- [ ] Task 2.4: Add a short comment near `clusters/kind/apps.yaml` or README explaining the app layer boundary.

**Exit Criteria:** A maintainer can tell which path owns every deployed component: Flux infrastructure, Flux apps, or fallback-only.

---

### Phase 3 — Fix OpenBao Values ConfigMap Stability

**Goal:** Ensure `HelmRelease` can reliably read its values.

- [ ] Task 3.1: Update `infrastructure/openbao/kustomization.yaml` to make the generated ConfigMap name stable.
  - Add `generatorOptions.disableNameSuffixHash: true`, or replace the generator with a static ConfigMap manifest.

- [ ] Task 3.2: Keep `HelmRelease.spec.valuesFrom[0].name` as `openbao-values` if the generated/static name is stable.

- [ ] Task 3.3: Render `kubectl kustomize infrastructure` and verify:
  - A ConfigMap named `openbao-values` exists in namespace `openbao`.
  - The `HelmRelease` values reference points to `openbao-values`.
  - The `HelmRepository` remains in the intended namespace.

**Exit Criteria:** Rendered infrastructure manifests contain a stable `openbao-values` ConfigMap and a matching `HelmRelease` reference.

---

### Phase 4 — Fix Fresh-Cluster Secret Ordering

**Goal:** Ensure `setup.sh` works on a brand-new cluster.

- [ ] Task 4.1: Before creating `rabbitmq-credentials`, ensure the `messaging` namespace exists.
  - Minimal fix: create/apply the namespace from `infrastructure/namespaces/messaging.yaml` before the secret command.
  - Alternative: apply all namespace manifests before secret creation.

- [ ] Task 4.2: Keep secret generation idempotent.
  - Existing behavior should remain: generate only if `rabbitmq-credentials` does not already exist.

- [ ] Task 4.3: Decide whether runtime secret generation remains acceptable for the lab.
  - Recommended near-term answer: yes, keep it for KISS and no plaintext Git secrets.
  - Future option: SOPS or External Secrets with OpenBao.

- [ ] Task 4.4: Validate shell syntax with `bash -n setup.sh`.

**Exit Criteria:** Fresh cluster setup cannot fail solely because `messaging` namespace is missing.

---

### Phase 5 — Make Hardening Consistent in the Flux Path

**Goal:** Ensure the security posture from the root overlay is not lost when Flux reconciles separate paths.

- [ ] Task 5.1: Identify which Deployments are rendered by the Flux app path after Phase 1.

- [ ] Task 5.2: Ensure each Flux-rendered Deployment receives the expected hardening:
  - `runAsNonRoot: true`
  - `allowPrivilegeEscalation: false`
  - `readOnlyRootFilesystem: true`
  - `seccompProfile.type: RuntimeDefault`
  - `capabilities.drop: [ALL]`

- [ ] Task 5.3: Choose one hardening strategy.

  **Option A — Keep root-only patching:**
  - Simpler, but Flux split paths can miss hardening.
  - Not recommended if Flux is the primary deploy path.

  **Option B — Apply patches in each Flux layer:**
  - Add the shared security patches to the Flux-managed app aggregate.
  - Recommended for consistency.

  **Option C — Put security contexts directly in workload manifests:**
  - More explicit and scanner-friendly.
  - More repetitive, but acceptable for a small repo.

  **Recommended:** Option B for DRY, then move to Option C only if scanner false positives remain too noisy.

- [ ] Task 5.4: Add `pod-security.kubernetes.io/enforce: restricted` to `infrastructure/namespaces/demo.yaml` if the demo workload is compatible.

- [ ] Task 5.5: Render and scan the Flux app layer.

**Exit Criteria:** The Flux-managed app path renders hardened workloads equivalent to the root overlay posture.

---

### Phase 6 — Improve Validation and CI Gates

**Goal:** Validate exactly what Flux will reconcile.

- [ ] Task 6.1: Update `make validate-kustomize` to include:
  - `kubectl kustomize apps`
  - `kubectl kustomize infrastructure`
  - `kubectl kustomize .`

- [ ] Task 6.2: Keep component-level validation for useful fast feedback:
  - `apps/demo`
  - `rabbitmq`
  - `headlamp`
  - `openbao`
  - `infrastructure`

- [ ] Task 6.3: Add Flux-aware validation commands where practical:
  - `flux diff kustomization infrastructure`
  - `flux diff kustomization apps`
  - `flux build kustomization` if available in the installed CLI version and suitable for local use.

- [ ] Task 6.4: Update `.github/workflows/IaC.yml` to render the same overlays used by Flux, not only the root overlay.

- [ ] Task 6.5: Keep rendered-manifest scanning authoritative.
  - Run Trivy/Checkov/Kyverno/Conftest against rendered manifests from the exact deploy paths.

**Exit Criteria:** CI and local Makefile validation fail if a Flux path is broken.

---

### Phase 7 — Documentation and Wiki Updates

**Goal:** Keep operational docs aligned with the code.

- [ ] Task 7.1: Update `README.md` project structure section after final path decisions.

- [ ] Task 7.2: Update README GitOps section with the exact reconciliation layers.

- [ ] Task 7.3: Update `wiki/concepts/kubernetes-flux-infrastructure-mapping.md` after implementation.

- [ ] Task 7.4: Append `wiki/log.md` with the implementation summary.

- [ ] Task 7.5: If a durable design decision emerges, add a short decision note to a wiki concept page or a new plan follow-up.

**Exit Criteria:** README, wiki index/log/concepts, and actual repository layout agree.

---

### Phase 8 — Optional Production-Posture Follow-Ups

**Goal:** Queue improvements that are valuable but not required for the local lab fix.

- [ ] Task 8.1: Replace Headlamp `cluster-admin` with least-privilege RBAC for normal use.
  - Keep a documented break-glass admin option if needed.

- [ ] Task 8.2: Add resource requests/limits to all workloads that lack them.

- [ ] Task 8.3: Evaluate SOPS with Flux for GitOps-native encrypted secrets.
  - Defer until there is a real need to store desired secret state in Git.

- [ ] Task 8.4: Evaluate External Secrets Operator with OpenBao.
  - Defer until OpenBao is initialized and used as the real source of secrets.

- [ ] Task 8.5: Add Flux controller hardening flags when multi-tenancy matters:
  - `--no-remote-bases=true`
  - `--no-cross-namespace-refs=true`
  - controller default service account restrictions.

- [ ] Task 8.6: Consider image automation only after a real application image pipeline exists.

**Exit Criteria:** Optional items remain explicitly deferred unless a concrete need appears.

---

## Verification Matrix

| Check | Command / Method | Required Result |
|---|---|---|
| App path builds | `kubectl kustomize apps` | Succeeds. |
| Infrastructure path builds | `kubectl kustomize infrastructure` | Succeeds. |
| Root aggregate builds | `kubectl kustomize .` | Succeeds. |
| Make validation | `make validate-kustomize` | Succeeds and includes Flux paths. |
| Setup shell syntax | `bash -n setup.sh` | Succeeds. |
| OpenBao values reference | inspect rendered infrastructure YAML | `HelmRelease` references existing `openbao-values`. |
| Secret namespace ordering | review/setup dry run | `messaging` exists before secret creation. |
| Flux dependency order | inspect `clusters/kind/apps.yaml` | `apps` depends on `infrastructure`. |
| Security hardening | inspect rendered app workloads | Expected `securityContext` values present. |
| NetworkPolicies | inspect rendered output | Default-deny plus explicit allow rules remain. |
| CI alignment | inspect workflow | CI renders Flux paths or equivalent deploy overlays. |

---

## Rollback Plan

If a phase breaks local deployment:

1. Revert only the files changed in the failing phase.
2. Re-run the verification commands from the previous successful phase.
3. Keep the plan file and add notes about the failure cause.
4. Do not remove prior working hardening or security-scanning controls to make validation pass.

---

## Risks and Mitigations

1. **Risk:** Moving workloads under `apps/` breaks relative Kustomize paths.
   - **Mitigation:** Prefer Phase 1 Option A first. Only move directories after confirming Kustomize build behavior.

2. **Risk:** Root and Flux overlays continue to drift.
   - **Mitigation:** Validate exact Flux paths and document root overlay as fallback/local aggregate.

3. **Risk:** OpenBao Helm values stop applying after ConfigMap changes.
   - **Mitigation:** Render infrastructure YAML and confirm matching ConfigMap and `valuesFrom` names before cluster testing.

4. **Risk:** Namespace creation in `setup.sh` duplicates Flux-owned namespace manifests.
   - **Mitigation:** Use `kubectl apply`/`create --dry-run=client -o yaml | kubectl apply -f -` style idempotency, and keep namespace manifests as source of truth.

5. **Risk:** Adding SOPS or External Secrets too early increases complexity.
   - **Mitigation:** Keep as Phase 8 optional follow-up unless plaintext/declarative secret requirements appear.

6. **Risk:** Tightening Headlamp RBAC blocks useful lab workflows.
   - **Mitigation:** Treat RBAC narrowing as optional production posture work, not a P0 fix.

---

## Recommended Execution Order

1. Phase 0 — baseline inventory.
2. Phase 1 — create valid `apps/kustomization.yaml`.
3. Phase 3 — fix OpenBao ConfigMap stability.
4. Phase 4 — fix setup namespace/secret ordering.
5. Phase 5 — align hardening in Flux path.
6. Phase 6 — improve validation gates.
7. Phase 2 — finalize/document Flux vs fallback ownership after concrete path changes are tested.
8. Phase 7 — update docs/wiki.
9. Phase 8 — defer production-posture follow-ups until needed.

---

## Implementation Results

**Status:** Implemented on 2026-05-08.

Completed changes:

- Added buildable `apps/kustomization.yaml`.
- Moved app/access overlays into `apps/rabbitmq/`, `apps/headlamp/`, and `apps/openbao/`.
- Added app-local security patches under `apps/_patches/security-context/`.
- Added buildable `clusters/kind/kustomization.yaml`.
- Stabilized OpenBao `openbao-values` naming with `generatorOptions.disableNameSuffixHash: true`.
- Fixed fresh-cluster RabbitMQ secret ordering in `setup.sh`.
- Updated `Makefile`, README, `.gitignore`, `.pre-commit-config.yaml`, `scripts/purge-secret-history.sh`, `config.env.example`, and `.github/workflows/IaC.yml`.
- Updated `wiki/concepts/kubernetes-flux-infrastructure-mapping.md` and `wiki/log.md`.

Validation completed:

- `make validate-kustomize` passed.
- `bash -n setup.sh scripts/security-scan.sh scripts/purge-secret-history.sh` passed.
- `kubectl kustomize infrastructure` renders stable `openbao-values` and the expected Helm resources.
- `kubectl kustomize apps` renders hardened demo, RabbitMQ, and Headlamp Deployments.

---

## Definition of Done

This improvement effort is complete when:

- [x] `apps/` is an explicit, buildable Flux app layer.
- [x] `infrastructure/` remains an explicit, buildable Flux infrastructure layer.
- [x] `OpenBao` `HelmRelease` values are resolved through a stable ConfigMap name.
- [x] `setup.sh` can run on a fresh cluster without RabbitMQ namespace ordering failure.
- [x] Flux-managed workloads retain the same hardening posture expected by the wiki.
- [x] Local and CI validation cover the actual Flux reconciliation paths.
- [x] README and wiki are updated to describe the final layout and operating model.
