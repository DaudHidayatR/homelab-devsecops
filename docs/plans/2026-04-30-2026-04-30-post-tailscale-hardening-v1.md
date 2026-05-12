# Post-Tailscale Hardening and Automation Improvements

## Objective

Apply targeted fixes and improvements to the `kind` DevSecOps lab based on the cumulative analysis from prior sessions. All changes are scoped to be high-value, low-risk, and do not introduce new tooling (no Ansible, no Go migration).

---

## Context

- Tailscale private admin access has been implemented via the Kubernetes Operator (`tailscale/install-operator.sh`).
- Admin services (Headlamp, OpenBao, RabbitMQ) are annotated with `tailscale.com/expose: "true"`.
- The repo is Kustomize-based with a single `config.env` for shell variables.
- `setup.sh` orchestrates `kind`, `istioctl`, `kubectl`, `helm`.
- `destroy.sh` still hardcodes `CLUSTER_NAME` instead of sourcing `config.env`.
- Image versions are scattered across raw YAML files and `config.env`.
- OpenBao UI is disabled (`ui.enabled: false`) despite README instructions telling users to open a browser.

---

## Implementation Plan

### Task 1: Centralize All Versions in `config.env`

- [ ] Add `RABBITMQ_VERSION`, `HEADLAMP_VERSION`, `SAMPLE_APP_VERSION` to `config.env`.
  - **Rationale:** Currently only `OPENBAO_IMAGE` and chart versions live in `config.env`. Headlamp, RabbitMQ, and sample-app versions are hardcoded in raw Deployment YAMLs. This creates two sources of truth.
- [ ] Remove hardcoded image tags from `apps/demo/sample-app/deployment.yaml`, `rabbitmq/core/deployment.yaml`, and `headlamp/headlamp.yaml`.
  - **Rationale:** Raw manifests should reference generic image names (e.g., `image: nginx`) so Kustomize can inject the tag.
- [ ] Add Kustomize `images` transformer blocks to `apps/demo/kustomization.yaml`, `rabbitmq/kustomization.yaml`, and `headlamp/kustomization.yaml`.
  - **Rationale:** The `images` patch is the idiomatic Kustomize way to manage image tags declaratively without editing raw Deployments.

### Task 2: Fix `destroy.sh` Cluster Name Bug

- [ ] Source `config.env` at the top of `destroy.sh`.
  - **Rationale:** `destroy.sh:4` hardcodes `CLUSTER_NAME="rootless-mesh"`. If a user changes the cluster name in `config.env`, `destroy.sh` will target the wrong cluster.
- [ ] Replace the hardcoded assignment with `source "${SCRIPT_DIR}/config.env"`.
  - **Rationale:** Keeps `destroy.sh` consistent with `setup.sh` behavior.

### Task 3: Enable OpenBao Web UI

- [ ] Change `ui.enabled: false` to `ui.enabled: true` in `openbao/values.yaml`.
  - **Rationale:** `README.md:84` instructs users to open `http://localhost:8200` in a browser. With the UI disabled, there is no web interface. Since Tailscale now provides secure private access, enabling the UI is safe and expected.

### Task 4: Add `Makefile` for Semantic Entrypoints

- [ ] Create a `Makefile` at the repository root with targets: `up`, `down`, `scan`, `tailscale`, `status`.
  - **Rationale:** Document common workflows in a discoverable, standard interface. Reduces cognitive load versus remembering individual script names.
- [ ] Ensure `make up` runs `./setup.sh`, `make down` runs `./destroy.sh`, `make scan` runs `./test-security-app.sh`, `make tailscale` runs `./tailscale/install-operator.sh`, and `make status` runs `kubectl get pods -A`.
  - **Rationale:** Each target maps to a natural verb that team members can discover with `make help` or `make` (default target).

### Task 5: Verify Kustomize Builds After Changes

- [ ] Run `kubectl kustomize apps/demo/` and confirm it renders the nginx Deployment with the correct tag from `images.newTag`.
  - **Rationale:** Validates that the `images` transformer works for the demo app.
- [ ] Run `kubectl kustomize rabbitmq/` and confirm it renders the RabbitMQ Deployment with the correct tag.
  - **Rationale:** Validates that the `images` transformer works for RabbitMQ.
- [ ] Run `kubectl kustomize headlamp/` and confirm the Headlamp Deployment retains its image tag correctly.
  - **Rationale:** Validates that the `images` transformer works for Headlamp and does not conflict with the existing Service annotation.
- [ ] Run `kubectl kustomize .` at the repository root and confirm no syntax errors.
  - **Rationale:** The root `kustomization.yaml` composes all overlays; a failure here blocks the entire setup.

### Task 6: Update Documentation

- [ ] Update `README.md` to reference `make up` / `make down` as the primary workflow.
  - **Rationale:** The Makefile becomes the canonical entrypoint; the README should teach new users to use it.
- [ ] Add a "Versioning" subsection to `README.md` explaining that all versions live in `config.env` and that Kustomize `images` patches inject them.
  - **Rationale:** Prevents future contributors from hardcoding versions in raw YAML again.

### Task 7: Record in Wiki Log

- [ ] Append an entry to `wiki/log.md` documenting the `config.env` centralization, `destroy.sh` fix, OpenBao UI enable, and `Makefile` addition.
  - **Rationale:** `AGENT.md` mandates append-only history tracking.

---

## Verification Criteria

- [ ] `config.env` contains all image/chart versions for every deployed component.
- [ ] No Deployment manifest contains a hardcoded image tag (generic image name only).
- [ ] `kubectl kustomize` succeeds for `apps/demo/`, `rabbitmq/`, `headlamp/`, and the repo root.
- [ ] `destroy.sh` sources `config.env` and uses `$CLUSTER_NAME` dynamically.
- [ ] `make up`, `make down`, `make scan`, `make tailscale`, `make status` all execute without error.
- [ ] OpenBao Helm values have `ui.enabled: true`.
- [ ] `wiki/log.md` contains a new entry dated 2026-04-30.

---

## Potential Risks and Mitigations

1. **Kustomize `images` transformer conflicts with existing patches**
   **Risk:** If a Deployment already has a full image string (`nginx:1.27-alpine`), the `images` patch may not override it correctly.
   **Mitigation:** Remove the tag from the raw manifest so only the image name remains (`nginx`). The `images` patch then injects `newTag`.

2. **OpenBao UI enable may require additional port exposure**
   **Risk:** Enabling `ui.enabled: true` exposes the UI container port, but the Helm chart may need a Service change.
   **Mitigation:** The official OpenBao Helm chart handles UI service creation automatically when `ui.enabled: true`. Verify with `helm template`.

3. **Makefile target names may collide with future files**
   **Risk:** If a contributor later adds a file literally named `up` or `scan`, Make will be confused.
   **Mitigation:** Declare all targets as `.PHONY` so Make never treats them as file-based rules.

## Alternative Approaches

1. **Use `just` instead of `Makefile`**
   - **Trade-off:** `just` is modern and user-friendly, but `make` is universally available. For a minimal lab, `make` is the pragmatic choice.

2. **Keep hardcoded versions in YAML and use `envsubst` in `setup.sh`**
   - **Trade-off:** `envsubst` is simpler than Kustomize `images`, but it requires preprocessing YAML before `kubectl apply -k`. Kustomize `images` is native, idempotent, and renders correctly with `kubectl kustomize` for inspection.

3. **Do not enable OpenBao UI, remove browser instructions instead**
   - **Trade-off:** Keeps the attack surface smaller, but contradicts the user's explicit need for web-based admin access via Tailscale. With Tailscale's tailnet-only exposure, the UI risk is acceptable.
