# DevSecOps Template Refinement Plan

## Objective

Evolve the kind-based Kubernetes lab into a reusable DevSecOps template by eliminating YAGNI configurations, deduplicating security patterns via Kustomize, centralizing configuration, and improving adherence to KISS, YAGNI, SOLID, DRY, and TDA principles.

## Implementation Plan

### Phase 1: Remove YAGNI Configurations

- [ ] Task 1.1: Remove OTLP tracing and metrics environment variables from Headlamp deployment
  - Remove `HEADLAMP_CONFIG_TRACING_ENABLED`, `HEADLAMP_CONFIG_METRICS_ENABLED`, `HEADLAMP_CONFIG_OTLP_ENDPOINT`, `HEADLAMP_CONFIG_SERVICE_NAME`, and `HEADLAMP_CONFIG_SERVICE_VERSION` from `headlamp/headlamp.yaml:49-58`
  - Rationale: No OpenTelemetry collector exists in the stack; these settings cause failed connection attempts and log noise

- [ ] Task 1.2: Remove unused metrics port from Headlamp container
  - Remove `containerPort: 9090` (metrics) from `headlamp/headlamp.yaml:62-63`
  - Rationale: Without OTLP export, the metrics port serves no purpose

- [ ] Task 1.3: Switch OpenBao from HA raft to standalone mode
  - In `openbao/values.yaml:51-73`, set `standalone.enabled: true`, `ha.enabled: false`, and remove `ha.replicas` and `ha.raft` configuration blocks
  - Preserve `dataStorage.enabled: true` for persistence
  - Rationale: A single-node lab gains no availability from HA raft but pays complexity cost in startup time, resource usage, and operational surface

- [ ] Task 1.4: Update OpenBao bootstrap instructions
  - Update `setup.sh:103-109` and `README.md:103-109` output messages to reflect standalone storage instead of raft
  - Rationale: Documentation must match the deployed architecture

### Phase 2: Centralize Configuration

- [ ] Task 2.1: Create `config.env` with shared constants
  - Extract `CLUSTER_NAME`, `OPENBAO_NAMESPACE`, `OPENBAO_RELEASE`, `OPENBAO_CHART_VERSION`, `OPENBAO_IMAGE`, `HEADLAMP_NAMESPACE`, `HEADLAMP_IMAGE`, `HEADLAMP_VERSION`, `RABBITMQ_NAMESPACE`, and `DEMO_NAMESPACE` into a single `config.env` file at the repository root
  - Rationale: Eliminates duplication between `setup.sh` and YAML manifests; one source of truth for template branding

- [ ] Task 2.2: Refactor `setup.sh` to source `config.env`
  - Replace hardcoded variables at `setup.sh:4-9` with `source config.env`
  - Update image drift detection logic (`setup.sh:65-68`) to use the centralized `OPENBAO_IMAGE` variable
  - Rationale: `setup.sh` becomes a generic executor rather than config owner, aligning with SRP and TDA

- [ ] Task 2.3: Inject config values into Kustomize manifests
  - Use Kustomize `configMapGenerator` or `replacement` transformers to consume `config.env` values during `kubectl apply -k`
  - Alternatively, use `envsubst` in `setup.sh` to render manifests from templates before application
  - Rationale: Ensures `config.env` is the single source of truth for both shell scripts and Kubernetes manifests

### Phase 3: Deduplicate via Kustomize

- [ ] Task 3.1: Create `bases/security-context/` with shared hardening components
  - Extract the repeated pod-level `securityContext` (`runAsNonRoot: true`, `seccompProfile: RuntimeDefault`) into a reusable base
  - Extract the repeated container-level `securityContext` (`runAsNonRoot`, `allowPrivilegeEscalation`, `readOnlyRootFilesystem`, `runAsUser`, `seccompProfile`, `capabilities: drop: [ALL]`) into a reusable base
  - Rationale: Every deployment repeats identical security hardening; a single base ensures consistency and simplifies updates

- [ ] Task 3.2: Create `bases/networkpolicy/` with default-deny template
  - Extract the `default-deny-ingress` NetworkPolicy pattern repeated across `apps/demo/networkpolicy.yaml`, `rabbitmq/networkpolicy.yaml`, and `openbao/networkpolicy.yaml` into a reusable base
  - Rationale: Default-deny is a universal zero-trust pattern; defining it once prevents copy-paste drift

- [ ] Task 3.3: Create `bases/namespace/` with common labels patch
  - Extract repeated `pod-security.kubernetes.io/audit: restricted` and `pod-security.kubernetes.io/warn: restricted` labels into a shared namespace base
  - Rationale: Namespace security labels should be consistent across all project namespaces

- [ ] Task 3.4: Add `kustomization.yaml` files to existing component directories
  - Create `kustomization.yaml` in `apps/demo/`, `apps/demo/sample-app/`, `rabbitmq/`, `rabbitmq/core/`, `openbao/`, and `headlamp/`
  - Reference appropriate bases and apply patches for component-specific values (namespace names, app labels, port numbers, ingress allowances)
  - Rationale: Enables `kubectl apply -k` workflows while preserving existing directory structure

- [ ] Task 3.5: Refactor `setup.sh` deployment commands to use Kustomize
  - Replace `kubectl apply -f` commands with `kubectl apply -k` where Kustomize overlays are defined
  - Keep `helm upgrade --install` for OpenBao since it remains Helm-managed
  - Rationale: TDA compliance — manifests declare full desired state rather than relying on imperative file-by-file application

- [ ] Task 3.6: Remove duplicated YAML fragments from component manifests
  - Strip hardcoded `securityContext` blocks from `apps/demo/sample-app/deployment.yaml`, `rabbitmq/core/deployment.yaml`, and `headlamp/headlamp.yaml` after they are injected via Kustomize bases
  - Strip duplicated `default-deny-ingress` rules from component `networkpolicy.yaml` files after they are injected via Kustomize bases
  - Strip duplicated labels from component `namespace.yaml` files after they are injected via Kustomize bases
  - Rationale: Prevents shadowing between base and overlay values

### Phase 4: Improve Reproducibility

- [ ] Task 4.1: Pin Headlamp image to a specific version tag
  - Replace `ghcr.io/headlamp-k8s/headlamp:latest` in `headlamp/headlamp.yaml:34` with a specific stable version
  - Update `config.env` with the pinned `HEADLAMP_VERSION` and `HEADLAMP_IMAGE`
  - Rationale: `latest` tags produce non-reproducible deployments; a reusable template must be deterministic

- [ ] Task 4.2: Audit remaining image references for version pinning
  - Verify `rabbitmq:3-management-alpine` and `nginx:alpine` are acceptably stable or pin to digest/version
  - Document pinning policy in `config.env` comments
  - Rationale: Ensures the entire template is reproducible, not just Headlamp

### Phase 5: Clarify `test-security-app.sh` Role

- [ ] Task 5.1: Update deprecation message to clarify local fallback purpose
  - Replace `test-security-app.sh:59-60` message to indicate the script serves as a local/offline fallback when GitLab CI is unavailable
  - Rationale: Prevents confusion about whether the script is dead code; documents its continued utility for pre-commit and air-gapped workflows

- [ ] Task 5.2: Add comment block documenting script purpose
  - Insert a header comment in `test-security-app.sh` explaining when to use the local script versus CI
  - Rationale: Improves discoverability for template consumers

### Phase 6: Update Documentation

- [ ] Task 6.1: Update `README.md` to reflect Kustomize-based deployment
  - Replace `kubectl apply -f` examples with `kubectl apply -k` where applicable
  - Document `config.env` and how to customize cluster names, namespaces, and image versions
  - Rationale: Documentation must match the actual provisioning workflow

- [ ] Task 6.2: Document OpenBao standalone bootstrap
  - Update OpenBao access instructions in `README.md` to remove raft-specific commands and reflect standalone mode
  - Rationale: Users following outdated raft instructions will encounter errors

- [ ] Task 6.3: Add Kustomize prerequisite note
  - Mention that Kustomize is built into `kubectl` (v1.14+) and requires no separate installation
  - Rationale: Reduces friction for users unfamiliar with Kustomize

## Verification Criteria

- [ ] `kubectl apply -k apps/demo/` produces a namespace with correct labels, a default-deny NetworkPolicy, and a sample-app deployment with the standard security context
- [ ] `kubectl apply -k rabbitmq/` produces equivalent output to the current imperative application
- [ ] `setup.sh` completes successfully after sourcing `config.env`
- [ ] Headlamp pod starts without OTLP connection errors in logs
- [ ] OpenBao deploys in standalone mode and initializes successfully
- [ ] `test-security-app.sh` runs all scanners without the "DEPRECATED" confusion
- [ ] No `latest` image tags remain in any deployment manifest
- [ ] `config.env` contains all cluster-level constants previously hardcoded in `setup.sh`
- [ ] Security contexts in all running pods match the pre-refactor state (runAsNonRoot, dropped capabilities, readOnlyRootFilesystem)

## Potential Risks and Mitigations

1. **Kustomize learning curve for template consumers**
   Mitigation: Provide a brief "Getting Started" section showing that `kubectl apply -k <dir>` is the only new command needed; Kustomize is built into kubectl

2. **OpenBao standalone data loss on existing deployments**
   Mitigation: Add a note that this is a lab template; data is ephemeral by design. Existing users must back up before switching modes

3. **Headlamp version pinning becomes stale**
   Mitigation: Document the pin in `config.env` and provide a one-line upgrade path

4. **Kustomize patches break if upstream bases change**
   Mitigation: Use strategic merge patches rather than JSON patches for better forward compatibility

5. **Namespace label drift between base and overlay**
   Mitigation: Run `kubectl diff -k` before applying overlays to verify merged output matches intent

## Alternative Approaches

1. **Helm umbrella chart instead of Kustomize**
   Would provide more powerful templating (loops, conditionals, and parameterized values) but adds Helm dependency management overhead. Suitable if the template grows beyond 6+ components or requires per-environment value overrides. Trade-off: steeper learning curve for consumers who only need YAML patches.

2. **Keep HA raft for OpenBao**
   Justified only if the template explicitly targets a multi-node production path or if the maintainer wants to demonstrate raft backup procedures. For a single-node `kind` lab, standalone is the correct default. Trade-off: users lose the ability to practice raft snapshots without re-enabling HA.

3. **Replace `setup.sh` with a Makefile or Taskfile**
   Would provide better task isolation, parallelization, and dependency tracking but adds another tool dependency. `setup.sh` is sufficient for a linear provisioning flow. Trade-off: Make/Task are more discoverable for CI integration but overkill for a single setup script.

4. **Use Kyverno instead of Gatekeeper for admission control**
   Kyverno uses native Kubernetes YAML patterns rather than Rego, reducing the policy learning curve. If the template later needs admission-time guardrails, evaluate Kyverno before Gatekeeper. Trade-off: less portable across non-Kubernetes systems compared to OPA/Gatekeeper.
