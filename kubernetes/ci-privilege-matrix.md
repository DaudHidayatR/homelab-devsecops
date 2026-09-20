# CI Kubernetes Privilege Matrix

Analysis-only deliverable (hardening P3): what the CI deploy identity can actually do,
what a normal release needs, and what should change. **No permissions were changed by
this document.** Evidence base: `.github/workflows/IaC.yml` @ main `143f1a7`,
`kubernetes/clusters/homelab/cluster-resources/rbac/ci-rbac.yaml`, CI run logs
(#209 v0.0.26 failure path, #234 v0.0.32 success path), and the RBAC history
(`c9a6819` → `07efa03`, 2026-05-09).

> **Coordination dependency (read first).** Card **t_bad33959** ("P0 — make CI
> validation-only") proposes deleting the `deploy` job entirely. If ratified, every
> operation below disappears from CI, CI holds no cluster credential at all, and only
> §1 (identity provenance) and §4 (separation principle) remain relevant. The matrix
> below is still the authoritative record of the *current* state and of what a
> restricted release identity must cover if a deploy job is ever reintroduced.

## 1. What identity does the production `KUBECONFIG` secret represent?

**Conclusion: the kind admin credential (`kubernetes-admin`, cluster-admin-equivalent) —
not the declared `ci-deployer` ServiceAccount.**

| # | Evidence | Source |
|---|----------|--------|
| 1 | The secret is produced by hand: "encode the kubeconfig and configure it as the production environment secret `KUBECONFIG`" — no repo path generates a `ci-deployer`-scoped kubeconfig | `README.md` L201 |
| 2 | Repo tooling generates exactly one kubeconfig: the kind admin one (`kind get kubeconfig` in `scripts/lib/cluster.sh`; server repaired to `127.0.0.1`/VPS IP for CI reachability). No `--as=` impersonation, no CSA/TokenRequest minting anywhere in `scripts/` | `scripts/lib/cluster.sh` L94–136, `config.env.example` L68–73 |
| 3 | The `ci-deployer` ServiceAccount exists only as an RBAC object applied by the `cluster-resources` Flux layer; **no workflow references it**, and no token for it is issued anywhere | `ci-rbac.yaml`, `kustomization.yaml` chain |
| 4 | OpenBao policy `ci-deployer.hcl` is a separate machine-identity layer (GitHub-OIDC/AppRole for secrets). It does not touch Kubernetes RBAC and is referenced by no workflow | `.../policies/apps/ci-deployer.hcl` |
| 5 | **Empirical over-privilege proof:** failed tag deploy #209 (v0.0.26) reached the `if: failure()` debug path; `kubectl get events -A` returned cluster-wide events from `istio-system`, `default`, and `flux-system`. `events` is **not** in the `ci-deployer` ClusterRole → the credential in use is not bound to it | run #209 job log, `Recent Events` section |
| 6 | Historical consistency: the same class of kubeconfig has driven `flux install`-capable runs since v0.0.1; `flux install` requires CRD + cluster-RBAC create, far beyond `ci-deployer` | workflow `Install Flux controllers` step, L316–321 |

Direct confirmation (one command, needs cluster access, **recommended before any
privilege change**): `kubectl auth whoami && kubectl auth can-i --list` with the
production credential.

**Security impact:** the production GitHub environment secret is a full cluster-admin
credential. Compromise of `TS_AUTHKEY` + `KUBECONFIG` (or of the `production`
environment) is cluster compromise. The declared restricted role is currently
documentation, not an enforcement boundary.

## 2. Operation matrix — declared role vs actual capability

Verbs of the declared `ci-deployer` ClusterRole (cluster-scoped):
`get/list/watch` on source kinds, `kustomizations`, `helmreleases`,
`namespaces/pods/services/configmaps`, `apps/*` workloads, `serviceaccounts`;
`patch/update` on `gitrepositories/helmrepositories/helmcharts/ocirepositories/buckets`
and `kustomizations`. **No `create`, no `delete`, no `*` anywhere.**

| Operation (workflow step) | Bootstrap-only? | Declared role | Actual (admin) | Notes |
|---|---|---|---|---|
| `flux install` (CRDs missing) | YES | NO (needs CRD/RBAC/NS create) | YES | Fresh-cluster path; never fires on steady state |
| `kubectl wait` deployments ×3 (flux-system) | no | YES | YES | get/watch on deployments |
| `kubectl apply -f -` GitRepository `flux-system` (tag pin) | create on fresh cluster; update otherwise | patch/update YES, **create NO** | YES | Run #234: `configured` (update); fresh cluster needs `create` → declared role would fail |
| `kubectl get/wait` GitRepository + artifact revision check | no | YES | YES | |
| `kubectl delete secret flux-system` (conditional) | YES (one-time migration hygiene) | **NO** (no delete verb) | YES | Effectively dead code; superseded by secretless GitRepository |
| `kubectl apply -k kubernetes/clusters/homelab` | create on fresh cluster; update otherwise | patch/update YES, **create NO** | YES | Root overlay resolves to **only** `flux/` = 6 Kustomization CRs (no raw workloads) |
| `flux reconcile source git` + 6× `flux reconcile kustomization` | no | YES (annotate = patch) | YES | Reconcile = GET + PATCH `reconcile.fluxcd.io/requestedAt` |
| Debug reads: `flux get kustomizations -A`, `describe kustomization`, `get deployments -A`, `get/describe pods -n demo`, headlamp pods | no (failure path) | mostly YES | YES | `kubectl get events -A` → **role NO** (proven used, run #209) |
| Smoke: `kubectl get pods -A`, `flux get all` | no | YES | YES | `flux get all` reads sources/kustomizations/helmreleases |

Reading the table against the two execution modes:

- **Normal release (steady state, what actually runs):** GitRepository patch/update,
  Kustomization patch/update, reconcile, controller and workload reads. The declared
  role covers *almost all* of it — the only gaps are `create` (unneeded steady-state)
  and events read (debug-only convenience).
- **Bootstrap/fresh cluster:** `flux install`, first GitRepository create, first
  Kustomization create. The declared role cannot do any of this **by design** — which
  is correct: bootstrap does not belong in CI (see §4).

## 3. Current vs required privileges

**Missing from the declared role (workflow steps the restricted identity could not
perform — documenting only, per the no-increase rule):**

1. `create` on `gitrepositories`/`kustomizations` — needed only by the fresh-cluster
   apply paths. Do **not** grant; remove the bootstrap steps from CI instead (t_bad33959
   removes them wholesale).
2. `get/list` on `events` (all namespaces) — used by the failure-debug step.
   Reduce the workflow (drop/replace the step) rather than widen the role.

**Unnecessary privileges held by the declared role (reduction candidates, separate PR
if CI keeps any deploy job):**

1. `patch/update` on `helmrepositories/helmcharts/ocirepositories/buckets` — the
   workflow never writes them; only the GitRepository is patched. Scope to
   `gitrepositories` (+ `kustomizations`) alone.
2. Cluster-scoped reads of `namespaces/serviceaccounts/configmaps/services` — none are
   read by the workflow; `pods`/`deployments` reads could be narrowed to the namespaces
   the debug/smoke steps actually touch (`flux-system`, `demo`, `kube-system`).
3. `helmreleases` read — `flux get all` reads them, so this one is legitimately used;
   keep if CI retains visibility steps.

**Unnecessary privileges held by the *actual* identity:** everything (it is
cluster-admin). The gap between §1 and this section is the entire problem: the repo
declares least privilege while deploying with a credential that has all of it.

## 4. Bootstrap-identity vs release-identity separation (recommendation)

Separation is **architectural** — it is a design recommendation for a separate PR, not
implemented here.

1. **Preferred: ratify t_bad33959 (CI validation-only).** CI then holds no cluster
   credential at all: bootstrap stays operator-side via `make up` / `flux bootstrap`
   (unchanged), releases are Flux reconciles of `main`, and the privilege question
   dissolves. The `production` environment, `TS_AUTHKEY`, and `KUBECONFIG` secrets
   should be deleted from the GitHub environment after one clean Flux-only deploy.
   This trivially satisfies the program target "normal CI needs cluster-admin = NO".
2. **If a tag-pinned CI deploy job is retained:** split identities.
   - *Bootstrap identity* — the existing admin kubeconfig, used only on the operator
     machine by `make up`. It must not live in GitHub; remove `flux install` and the
     first-apply paths from CI.
   - *Release identity* — a `ci-deployer`-scoped kubeconfig (short-lived SA token,
     e.g. `kubectl create token ci-deployer --duration=…`, wrapped in a kubeconfig and
     rotated per release) holding exactly: `patch/update/get/list/watch` on
     `gitrepositories` + `kustomizations` in `flux-system` (ideally Role/namespaced,
     not ClusterRole), plus the read verbs the smoke/debug steps use. Two GitHub
     secrets, rotated independently; the admin one never leaves the operator machine.
3. **Either way:** never grant `cluster-admin` to CI (standing rule), and never let the
   tag-pin mechanism mutate the Git source *and* hold an unrestricted credential at the
   same time — that combination (current state) lets any `v*` tag on any branch drive
   full-cluster imperative apply as admin.
