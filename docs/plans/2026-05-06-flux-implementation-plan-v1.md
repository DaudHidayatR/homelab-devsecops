# Flux GitOps Migration Plan for infra/kind

## Objective

Migrate the existing `kind` DevSecOps lab from imperative `kubectl apply -k` and `helm install` workflows to a declarative GitOps model using Flux CD. The implementation must strictly adhere to **KISS, YAGNI, TDA, SOLID, and DRY** principles, treating this local lab as a learning environment rather than a production platform.

**Scope Inclusions:**
- Bootstrap Flux onto the `kind` cluster
- Re-use existing Kustomize overlays without manifest duplication
- Convert OpenBao from imperative Helm to declarative `HelmRelease`
- Establish `clusters/kind/` as the single Flux entry point
- Update `setup.sh`, `Makefile`, and documentation

**Scope Exclusions (YAGNI):**
- Image automation (static demo app, no CI pipeline)
- Notification controller (no Slack/Discord webhook targets)
- SOPS/Sealed Secrets (no secrets committed to Git in this lab)
- Multi-tenancy, sharding, or OCI artifacts
- Multi-cluster or repo-per-environment patterns

---

## Initial Assessment

### Project Structure Summary

The repository (`project-ssdlc-devsecops-boilerplate/infra/kind`) is a local Kubernetes lab built on `kind`. It already uses Kustomize overlays, centralized versioning in `config.env`, and a `Makefile` for human-friendly commands. The architecture is:

- **Root overlay:** `kustomization.yaml` aggregates all components
- **Apps:** `apps/demo/` (sample nginx app with security hardening)
- **Infrastructure components:** `rabbitmq/`, `headlamp/`, `openbao/`, `istio/`, `tailscale/`
- **Shared bases:** `bases/` (security contexts, labels, network policies)
- **Scripts:** `setup.sh` (imperative cluster creation + deployment), `destroy.sh`

### Key Files to Analyze

| File | Purpose | Flux Relevance |
|------|---------|----------------|
| `setup.sh` | Creates `kind` cluster, namespaces, installs Helm charts, applies Kustomize | Must be split: cluster creation vs. GitOps reconciliation |
| `kustomization.yaml` | Root Kustomize overlay | Flux `Kustomization` CRD will point here |
| `config.env` | Centralized image/chart versions | Re-use via Kustomize `images` transformers |
| `apps/demo/kustomization.yaml` | App overlay with security contexts | Directly consumed by Flux |
| `openbao/values.yaml` | Helm values for OpenBao | Referenced by `HelmRelease` |
| `Makefile` | Human-friendly commands (`up`, `down`, `scan`) | Add `sync`, `status`, `diff` targets |

### Current Pain Points (Why Flux?)

1. **Drift persistence:** Manual `kubectl edit` changes survive until next `setup.sh` run
2. **No reconciliation loop:** Changes to Git are not automatically applied
3. **Imperative Helm:** OpenBao is installed via `helm upgrade --install` inside `setup.sh`; version bumps require re-running the script
4. **Mixed concerns:** `setup.sh` handles cluster lifecycle, namespace creation, Helm installs, and Kustomize applies

### Risk Prioritization

| Rank | Risk | Likelihood | Impact | Rationale |
|------|------|------------|--------|-----------|
| 1 | Over-engineering for a local lab | High | Medium | YAGNI violations are the biggest threat to this project's simplicity |
| 2 | `setup.sh` refactor breaks existing workflow | Medium | Medium | The script is the primary interface; must remain functional during migration |
| 3 | HelmRelease migration causes OpenBao data loss | Low | High | OpenBao uses Raft storage in `kind`; HelmRelease changes should not affect PVCs, but must be validated |
| 4 | Flux bootstrap requires Git provider token | Medium | Low | Adds a one-time setup step; can use generic `flux bootstrap git` if GitHub is unavailable |

---

## Implementation Plan

### Phase 0: Foundation — Restructure for Flux Without Installing Flux

**Goal:** Prepare the repository so Flux has a clean, minimal surface area. No Flux controllers installed yet.

- [ ] **Task 0.1.** Create `clusters/kind/` directory structure as the single Flux entry point.
  - *Rationale:* This mirrors the official Flux monorepo pattern and separates GitOps configuration from application manifests.

- [ ] **Task 0.2.** Create `infrastructure/namespaces/` with declarative Namespace manifests for `demo`, `openbao`, `rabbitmq`, `headlamp`.
  - *Rationale:* Eliminates imperative `kubectl create namespace` from `setup.sh` (TDA + SRP).

- [ ] **Task 0.3.** Refactor `setup.sh` to remove namespace creation and Helm install logic.
  - *Rationale:* `setup.sh` should only create the `kind` cluster and bootstrap Flux. Everything else becomes declarative.

- [ ] **Task 0.4.** Verify all existing Kustomize overlays still build correctly after directory changes.
  - *Rationale:* Prevents drift between file moves and `kustomization.yaml` references.

- [ ] **Task 0.5.** Update `Makefile` with `validate-kustomize` target.
  - *Rationale:* Provides immediate feedback on Kustomize syntax before Flux attempts reconciliation.

### Phase 1: Minimal Flux Bootstrap

**Goal:** Install Flux and make it manage your existing Kustomize overlays. No Helm migration yet.

- [ ] **Task 1.1.** Add `flux` CLI prerequisite check to `setup.sh`.
  - *Rationale:* Fail fast if the user does not have the Flux CLI installed.

- [ ] **Task 1.2.** Execute `flux bootstrap github` (or `flux bootstrap git`) targeting `clusters/kind/`.
  - *Rationale:* Bootstrap is the only supported installation method. It ensures Flux manages its own upgrades via Git.

- [ ] **Task 1.3.** Create `clusters/kind/infrastructure.yaml` — a `Kustomization` CRD pointing to `./infrastructure/`.
  - *Rationale:* Separates foundational resources (namespaces, Istio) from applications.

- [ ] **Task 1.4.** Create `clusters/kind/apps.yaml` — a `Kustomization` CRD pointing to `./apps/`, with `dependsOn: [infrastructure]`.
  - *Rationale:* Ensures namespaces and CRDs exist before apps deploy (SOLID — Dependency Inversion Principle).

- [ ] **Task 1.5.** Verify `flux get all` shows `Ready=True` for all resources.
  - *Rationale:* Confirms the bootstrap succeeded before proceeding.

- [ ] **Task 1.6.** Test drift detection: manually `kubectl edit` the `demo` Deployment and verify Flux reverts it within the reconciliation interval.
  - *Rationale:* Validates the core GitOps guarantee — cluster state matches Git state.

### Phase 2: Declarative Helm Migration (OpenBao)

**Goal:** Convert OpenBao from imperative `helm upgrade --install` to a Flux `HelmRelease`.

- [ ] **Task 2.1.** Create `infrastructure/openbao/helmrepository.yaml` referencing the OpenBao Helm chart repository.
  - *Rationale:* Tells the source-controller where to fetch charts.

- [ ] **Task 2.2.** Create `infrastructure/openbao/helmrelease.yaml` referencing the chart version and existing `values.yaml`.
  - *Rationale:* Declarative replacement for `helm upgrade --install`.

- [ ] **Task 2.3.** Use Kustomize `configMapGenerator` in `infrastructure/openbao/kustomization.yaml` to inject `values.yaml` as a ConfigMap.
  - *Rationale:* Avoids duplicating values. The existing `values.yaml` remains the single source of truth (DRY).

- [ ] **Task 2.4.** Remove OpenBao Helm logic from `setup.sh`.
  - *Rationale:* Eliminates the last imperative deployment step from the bootstrap script.

- [ ] **Task 2.5.** Verify OpenBao reconciles correctly via `flux get helmreleases` and remains accessible.
  - *Rationale:* Ensures no data loss or functional regression.

### Phase 3: Image Automation (YAGNI Gate — Skip Unless Criteria Met)

**Goal:** Automate container image tag updates. **This phase is explicitly gated.**

- [ ] **Task 3.0.** Answer YAGNI gate questions:
  - Do you push new app images more than once per week?
  - Do you have a CI pipeline building and pushing images?
  - Does manual `config.env` editing cause errors or toil?
  - *Rationale:* For a static `nginx:1.27.5` demo app, the answer is No. Skip this phase.

- [ ] **Task 3.1.** (Conditional) If criteria are met, create `ImageRepository`, `ImagePolicy`, and `ImageUpdateAutomation` for the single app that changes.
  - *Rationale:* Image automation controllers are powerful but add complexity. Apply only where justified.

### Phase 4: Tooling & Documentation Integration

**Goal:** Ensure the Makefile, README, and wiki reflect the new GitOps workflow.

- [ ] **Task 4.1.** Add `sync`, `status`, and `diff` targets to `Makefile`.
  - *Rationale:* Replaces the habit of re-running `setup.sh` to apply changes.

- [ ] **Task 4.2.** Update `README.md` with Flux workflow instructions (`make up`, `make sync`, `flux get all`).
  - *Rationale:* The README is the primary user interface for this repo.

- [ ] **Task 4.3.** Add `wiki/concepts/flux-implementation-plan.md` documenting the phased approach and principle rationale.
  - *Rationale:* Preserves architectural decisions for future maintainers.

- [ ] **Task 4.4.** Update `wiki/log.md` with implementation event entry.
  - *Rationale:* Maintains chronological history of project evolution.

- [ ] **Task 4.5.** Update `wiki/index.md` to reference the new plan page.
  - *Rationale:* Keeps the wiki catalog current.

---

## Verification Criteria

- [ ] `make up` creates the `kind` cluster and bootstraps Flux successfully.
- [ ] `flux get all` reports `Ready=True` for `GitRepository`, `Kustomization`, and `HelmRelease` resources.
- [ ] Modifying `apps/demo/sample-app/deployment.yaml` in Git and pushing triggers automatic reconciliation within 5 minutes.
- [ ] Manual `kubectl edit deployment nginx -n demo` is automatically reverted by Flux.
- [ ] `make down` destroys the cluster cleanly; re-running `make up` restores the full state from Git.
- [ ] OpenBao remains functional after migration from imperative Helm to `HelmRelease`.
- [ ] No plaintext secrets are committed to Git during migration.

---

## Potential Risks and Mitigations

1. **Over-engineering (YAGNI violation)**
   - *Mitigation:* Hard gate on Phase 3. Explicitly exclude notifications, SOPS, image automation, and multi-tenancy from initial implementation. Document excluded items with "defer until needed" rationale.

2. **`setup.sh` refactor breaks existing workflow**
   - *Mitigation:* Keep `setup.sh` functional at every commit. Phase 0 only *moves* logic (namespaces to YAML), Phase 1 only *adds* Flux bootstrap, Phase 2 only *replaces* Helm commands. No single commit breaks `make up`.

3. **HelmRelease migration causes OpenBao state issues**
   - *Mitigation:* OpenBao in `kind` uses a PVC for Raft storage. The `HelmRelease` references the same `values.yaml`, which already configures persistence. Validate by checking `kubectl get pvc -n openbao` before and after migration.

4. **Flux bootstrap requires external Git provider credentials**
   - *Mitigation:* Support both `flux bootstrap github` and `flux bootstrap git` (generic HTTPS/SSH). Document the generic path for users without GitHub tokens.

5. **Directory restructuring breaks existing Kustomize references**
   - *Mitigation:* Run `kustomize build` on every overlay after any file move. Add this as a CI gate if/when CI is introduced.

---

## Alternative Approaches

1. **Argo CD instead of Flux**
   - *Description:* Argo CD provides a web UI and similar GitOps reconciliation.
   - *Trade-offs:* Heavier resource footprint in `kind`, requires a UI component, less CLI-native. Flux aligns better with this project's terminal-first, Makefile-driven workflow.
   - *Verdict:* Not selected. Flux is lighter and more scriptable.

2. **Keep imperative `setup.sh`, add a cronjob for `kubectl apply -k`**
   - *Description:* A Kubernetes CronJob periodically runs `kubectl apply -k` inside the cluster.
   - *Trade-offs:* Re-invents Flux poorly. No drift detection, no pruning, no Helm support, no status reporting.
   - *Verdict:* Not selected. Reinventing a CNCF-graduated tool violates KISS.

3. **Use OCI artifacts (Gitless GitOps)**
   - *Description:* Build Kustomize output into OCI images, push to registry, cluster pulls from registry.
   - *Trade-offs:* Adds CI pipeline complexity for building and pushing artifacts. Overkill for a single-node `kind` cluster.
   - *Verdict:* Not selected. Git-based GitOps is sufficient for this scope.

4. **Migrate everything to Helm instead of Kustomize**
   - *Description:* Convert all Kustomize overlays to Helm charts.
   - *Trade-offs:* Massive rewrite for zero functional gain. Existing Kustomize structure is clean and already Flux-compatible.
   - *Verdict:* Not selected. Violates DRY and YAGNI — the Kustomize overlays already work.

---

## Assumptions Made

1. The `kind` cluster is a single-node local development lab, not a production or shared environment.
2. The user has access to a Git provider (GitHub recommended, generic Git fallback acceptable).
3. The existing Kustomize overlays (`apps/demo/`, `rabbitmq/`, `headlamp/`) are functionally correct and do not need manifest-level changes.
4. OpenBao data in `kind` is ephemeral — the lab can be destroyed and recreated without data loss concerns, though migration should still preserve PVC bindings.
5. No CI/CD pipeline exists yet; therefore, image automation and webhook receivers are deferred.
6. The primary user interface for this project is the terminal (`Makefile`, `flux` CLI), not a web dashboard.

---

## Design Principles Applied (Per Decision)

| Decision | Principle | Rationale |
|----------|-----------|-----------|
| One repo, one cluster, one branch | KISS | No multi-environment or multi-team complexity |
| No image automation in Phase 1-2 | YAGNI | Static demo app; no CI pipeline |
| No SOPS/Sealed Secrets | YAGNI | No secrets committed to Git in this lab |
| Re-use existing `kustomization.yaml` files | DRY | Zero manifest duplication |
| `setup.sh` creates cluster only; Flux manages resources | SRP + TDA | Separation of cluster lifecycle from resource state |
| `apps` depends on `infrastructure` via `dependsOn` | DIP | Apps depend on abstraction, not execution order |
| `HelmRelease` delegates to `helm-controller` | TDA | Manifest declares intent; controller decides execution |
| Phased rollout with hard gates | KISS + YAGNI | Each phase adds value before the next begins |
