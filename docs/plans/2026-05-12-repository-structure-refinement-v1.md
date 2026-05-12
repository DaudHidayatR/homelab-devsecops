# Implementation Plan: Repository Structure Refinement

## Objective

Align the `infra/kind/` directory layout with Flux CD and Kustomize best practices. Remove dead code, fix naming conventions, separate plans from deployment manifests, and resolve the blurred boundary between `infrastructure/` and `apps/`.

Based on root cause analysis from the [Flux Folder Remapping](../wiki/concepts/flux-folder-remapping.md) wiki page and cross-referenced against the [Flux monorepo guide](https://fluxcd.io/flux/guides/repository-structure/#monorepo) and the [Kustomize Glossary](https://kubectl.docs.kubernetes.io/references/kustomize/glossary/).

---

## Root Cause Summary

| Issue | Root Cause | Best Practice Source |
|---|---|---|
| Root `kustomization.yaml` duplicates Flux | Project predates Flux; kept as fallback | Flux monorepo guide: one entry point per cluster in `clusters/` |
| `apps/openbao/` split from `infrastructure/openbao/` | Classification error: NetworkPolicy treated as "app" when it controls infra access | Flux guide: one component = one directory. Infra goes in `infrastructure/`. |
| `bases/` misnamed | Kustomize terminology confusion: consumed via `patches:`, not `resources:` | Kustomize Glossary: `base` = directory with `kustomization.yaml` referenced via `resources:` |
| `istio/` dead code | Migration residue from imperative `istioctl` to Flux `HelmRelease` | Universal: dead code is harmful |
| `plans/` mixed with manifests | Transient project management inside deployment directory | General: separate deploy config from project management |
| `wiki/` and `raw/` NOT moved | Intentional LLM knowledge system per `AGENT.md`; not in Kustomize build path | N/A — valid design pattern, zero Kustomize risk |

---

## Implementation Plan

### Phase 1: Dead Code Removal

- [ ] **1.1 Remove top-level `istio/` directory**

  The `istio/istio-operator.yaml` is the legacy `istioctl` operator manifest. Istio is now fully managed via Flux `HelmRelease` in `infrastructure/istio/`. Delete `istio/istio-operator.yaml` and the empty `istio/` directory.

  **Root cause:** Migration residue. Istio was moved to Flux in audit remediation task M6 but the old file wasn't cleaned up.
  **Best practice:** Universal — dead code confuses users about which path is authoritative.

### Phase 2: Boundary Cleanup

- [ ] **2.1 Merge `apps/openbao/` into `infrastructure/openbao/`**

  Move `networkpolicy.yaml` and `default-deny-ingress.yaml` from `apps/openbao/` into `infrastructure/openbao/`. Register them in `infrastructure/openbao/kustomization.yaml`. Remove `openbao/` from `apps/kustomization.yaml:8`. Remove the `namespace: openbao` line from `apps/openbao/kustomization.yaml` (or delete the file if empty).

  **Root cause:** Classification ambiguity. The NetworkPolicies control which namespaces can reach OpenBao — they are access-control for an infra component, not standalone app manifests.
  **Best practice:** Flux monorepo guide — one component = one directory. OpenBao is infrastructure; all its resources should be in `infrastructure/openbao/`.

- [ ] **2.2 Rename `bases/` to `patches/` and relocate the patch**

  The `bases/namespace/common-labels.yaml` is a strategic merge patch consumed via `patches:`. Rename `bases/` to `patches/`. Move the patch to be applied in `infrastructure/namespaces/kustomization.yaml` via a `patches:` directive. Remove the old `bases/` directory if empty.

  **Root cause:** Terminology confusion. In Kustomize, a "base" is a directory with its own `kustomization.yaml` referenced via `resources:` in overlays. This file has no `kustomization.yaml` and is consumed via `patches:`. The directory name `bases/` is misleading.
  **Best practice:** [Kustomize Glossary](https://kubectl.docs.kubernetes.io/references/kustomize/glossary/) — reserve `base/` for composable directories.

### Phase 3: Documentation Separation

- [ ] **3.1 Move `plans/` to repo-root `docs/plans/`**

  Move all `.md` files from `infra/kind/plans/` to a new `docs/plans/` directory at the repository root level. Create the target directory under `/docs/plans/`.

  **Root cause:** Plans are transient project management artifacts — task plans, audit remediation plans, implementation plans. They serve a different lifecycle than deployment manifests.
  **Why NOT wiki/ and raw/:** `wiki/` and `raw/` are part of the LLM-maintained knowledge system defined by `AGENT.md`. They are not in any Kustomize `resources:` path, so they pose zero Kustomize build risk. Moving them would break the AGENT.md workflow.

### Phase 4: Root Kustomization and Fallback Simplification

- [ ] **4.1 Simplify root `kustomization.yaml`**

  Remove the `resources:` section (lines 4-7) from root `kustomization.yaml`, keeping only the `patches:` directive. Update `setup.sh` fallback paths to apply `infrastructure/` then `apps/` separately instead of the root aggregate.

  **Root cause:** The root kustomization predates Flux. It was the original deployment mechanism. After Flux was introduced, it remained as a fallback, creating dual deploy paths (Flux + kubectl).
  **Best practice:** Flux guide — one entry point per cluster. The root fallback is kept but simplified to avoid duplicating Flux's reconciliation scope.

- [ ] **4.2 Update `setup.sh` fallback paths**

  In `setup.sh:84,89,94`, replace `kubectl apply -k "${SCRIPT_DIR}"` with sequential apply: `kubectl apply -k "${SCRIPT_DIR}/infrastructure"` then `kubectl apply -k "${SCRIPT_DIR}/apps"`. The namespace directory is already handled by `infrastructure/namespaces/`.

### Phase 5: Makefile and README Updates

- [ ] **5.1 Update `Makefile` targets**

  Update `validate-kustomize` target (line 34-35) to remove `apps/openbao` validation, and add `infrastructure/openbao` validation. Remove the root overlay validation (line 24-25) or update it to validate the simplified root kustomization.

- [ ] **5.2 Update `README.md` Project Structure and references**

  Update the "Project Structure" section: remove `istio/` from the tree, merge `apps/openbao/` into infrastructure, rename `bases/` to `patches/`. Update the `apps/openbao/` line (23): merge OpenBao NetworkPolicies description into infrastructure.
  Update `wiki/` links (lines 137-141) if any paths changed (they haven't — wiki stays where it is).

- [ ] **5.3 Update `wiki/log.md` with the refinement entry**

  Add an append-only log entry documenting the structural changes, with cross-links to the new `flux-folder-remapping.md` concept page and to the previous `kubernetes-flux-infrastructure-mapping.md` page.

---

## Verification Criteria

- [ ] `kustomize build infrastructure` succeeds with all openbao resources (HelmRelease + NetworkPolicies)
- [ ] `kustomize build apps` succeeds without openbao resources
- [ ] Top-level `istio/` directory no longer exists
- [ ] `bases/` directory renamed to `patches/` or removed
- [ ] Root `kustomization.yaml` simplified (resources removed)
- [ ] `plans/` moved to repo-root `docs/plans/`
- [ ] `wiki/` and `raw/` remain at `infra/kind/` (NOT moved)
- [ ] `setup.sh` fallback applies `infrastructure/` then `apps/` sequentially
- [ ] `make validate-kustomize` succeeds with updated paths
- [ ] Internal links in `README.md` and `wiki/concepts/kubernetes-flux-infrastructure-mapping.md` are correct

## Potential Risks and Mitigations

1. **Flux pruning openbao NetworkPolicies when removed from apps path**
   Mitigation: The Flux `apps` Kustomization points to `./apps`. After removing `apps/openbao/` from `apps/kustomization.yaml`, Flux will prune the NetworkPolicies from the `apps` reconciliation scope. Ensure they are already present in `infrastructure/openbao/kustomization.yaml` BEFORE this change reconciles. The `infrastructure` Kustomization runs first due to `dependsOn`, so the NetworkPolicies will exist in the cluster before the apps Kustomization prunes its copy.

2. **Kustomize build failure from path changes**
   Mitigation: Run `kustomize build` on each affected directory after each change.

3. **Makefile `validate-kustomize` targets broken**
   Mitigation: Update path references in same commit as the directory changes.

4. **Wiki internal links broken**
   Mitigation: Wiki stays where it is — no links to update. Only `plans/` moves, and no files link to plan files.

## Files Affected

| Phase | Files Modified | Files Created | Files Deleted |
|---|---|---|---|
| 1.1 | — | — | `istio/istio-operator.yaml`, `istio/` directory |
| 2.1 | `apps/kustomization.yaml`, `infrastructure/openbao/kustomization.yaml` | — | `apps/openbao/kustomization.yaml`, `apps/openbao/networkpolicy.yaml`, `apps/openbao/default-deny-ingress.yaml` (moved) |
| 2.2 | `infrastructure/namespaces/kustomization.yaml`, `kustomization.yaml` | `patches/namespace/common-labels.yaml` (from `bases/`) | `bases/namespace/common-labels.yaml` (moved), `bases/` directory |
| 3.1 | — | `docs/plans/` at repo root | `infra/kind/plans/` directory |
| 4.1 | `kustomization.yaml` | — | — |
| 4.2 | `setup.sh` | — | — |
| 5.1 | `Makefile` | — | — |
| 5.2 | `README.md` | — | — |
| 5.3 | `wiki/log.md` | — | — |
