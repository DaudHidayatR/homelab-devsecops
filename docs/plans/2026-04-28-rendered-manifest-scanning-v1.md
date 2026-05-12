# Rendered Manifest Scanning Plan (Option A)

## Objective

Eliminate 100% false-positive rate in Trivy Kubernetes misconfiguration scans by switching from raw-file scanning (`trivy fs`) to **rendered-manifest scanning** (`kustomize build | trivy config`). This ensures Trivy evaluates the actual Kubernetes state after Kustomize patches are applied, not the un-hardened source files.

## Context

The current `test-security-app.sh` runs:
```bash
trivy fs --scanners vuln,secret,config ...
```

This scans raw YAML files on disk. All 7 HIGH-severity findings (KSV-0014, KSV-0118) are **false positives** because `kustomization.yaml` injects `securityContext` patches at deployment time. The raw files lack these contexts, but the rendered manifests include them.

---

## Implementation Plan

### Phase 1: Prerequisites & Validation

- [ ] **Task 1.1**: Verify `kustomize` CLI availability in target environments
  - Check if `kustomize` is installed in developer workstations and CI runners
  - If missing, document installation: `https://kubectl.docs.kubernetes.io/installation/kustomize/`
  - Alternative: use `kubectl kustomize` (built-in since kubectl v1.14)
  - Rationale: The new scan pipeline depends on `kustomize build`

- [ ] **Task 1.2**: Verify Kustomize build succeeds without errors
  - Run `kustomize build /home/sagash/Documents/project-ssdlc-devsecops-boilerplate/infra/kind` and confirm clean output
  - Check for duplicate keys, broken JSON patches, or missing resources
  - Rationale: A broken Kustomize build will break the scan pipeline

- [ ] **Task 1.3**: Create `.trivyignore` as safety fallback
  - Create `.trivyignore` at repo root with:
    ```
    # These checks are enforced via Kustomize patches at build time.
    # Raw-file scanning reports false positives; rendered-manifest scanning is authoritative.
    KSV-0014
    KSV-0118
    ```
  - Rationale: Provides immediate false-positive suppression while transitioning scan strategies

---

### Phase 2: Script Implementation

- [ ] **Task 2.1**: Add rendered-manifest scan to `test-security-app.sh`
  - Insert after line 108 (after existing Trivy scans, before Grype):
    ```bash
    # ─── 1d. RENDERED MANIFEST SCAN ───
    echo ""
    echo "==> 1d. Trivy scan of rendered Kustomize manifests..."

    if command -v kustomize >/dev/null 2>&1; then
      KUSTOMIZE_CMD="kustomize"
    elif kubectl kustomize --help >/dev/null 2>&1; then
      KUSTOMIZE_CMD="kubectl kustomize"
    else
      echo "WARNING: neither kustomize nor kubectl kustomize available; skipping rendered manifest scan." >&2
      KUSTOMIZE_CMD=""
    fi

    if [ -n "$KUSTOMIZE_CMD" ]; then
      if $KUSTOMIZE_CMD build "$SCRIPT_DIR" | "$RUNTIME" run --rm -i \
        --memory=2g --cpus=1 \
        "$TRIVY_IMAGE" config --scanners kubernetes - \
        --severity HIGH,CRITICAL \
        --format sarif \
        --output trivy-rendered.sarif; then
        echo "OK: Rendered manifest scan"
      else
        echo "FAILED: Rendered manifest scan" >&2
        FAILURES=$((FAILURES + 1))
      fi
    fi
    ```
  - Rationale: Scans the actual output that `kubectl apply -k` sends to the API server

- [ ] **Task 2.2**: Add `SCRIPT_DIR` definition for portability
  - Add near line 16 (after `set`):
    ```bash
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    ```
  - Rationale: Ensures `kustomize build` uses the script's directory, not `$PWD` which may differ

- [ ] **Task 2.3**: Update report listing section (lines 179-197)
  - Add `trivy-rendered.sarif` to the `for file in ...` loop
  - Rationale: New report artifact must be listed in the final summary

- [ ] **Task 2.4**: Add container resource limits to `run_scan`
  - Modify `run_scan` (line 58) to include `--memory=4g --cpus=2` in the `docker run`/`podman run` invocation
  - Rationale: Prevents scanner containers from consuming all host resources on large manifests

---

### Phase 3: Strategic Refinement

- [ ] **Task 3.1**: Consolidate Trivy invocations
  - Replace three separate Trivy `fs` runs (JSON, Table, SARIF) with a single invocation using multiple `--format`/`--output` pairs
  - Example:
    ```bash
    trivy fs \
      --scanners vuln,secret,config,license \
      --severity HIGH,CRITICAL \
      --ignore-unfixed \
      --dependency-tree \
      --format json --output trivy-report.json \
      --format sarif --output trivy-report.sarif \
      --format table --output trivy-report.txt \
      .
    ```
  - Rationale: Eliminates ~66% of Trivy execution time by avoiding redundant DB downloads and scans

- [ ] **Task 3.2**: Pin image versions
  - Replace all `:latest` tags with specific semver versions:
    ```bash
    TRIVY_IMAGE="${TRIVY_IMAGE:-ghcr.io/aquasecurity/trivy:0.70.0}"
    SEMGREP_IMAGE="${SEMGREP_IMAGE:-docker.io/semgrep/semgrep:1.117.0}"
    SYFT_IMAGE="${SYFT_IMAGE:-docker.io/anchore/syft:1.21.0}"
    GITLEAKS_IMAGE="${GITLEAKS_IMAGE:-docker.io/zricethezav/gitleaks:8.24.0}"
    GRYPE_IMAGE="${GRYPE_IMAGE:-docker.io/anchore/grype:0.91.0}"
    ```
  - Rationale: Reproducible scans; prevents unexpected rule/DB changes during IaC refactoring

- [ ] **Task 3.3**: Add `.gitignore` entries for report artifacts
  - Create or update `.gitignore`:
    ```gitignore
    # Security scan reports (may contain secret fragments or vulnerability data)
    trivy-report.*
    trivy-rendered.*
    grype-report.*
    gitleaks-report.*
    semgrep-report.*
    sbom-*.json
    ```
  - Rationale: Prevents accidental commit of reports containing sensitive findings

- [ ] **Task 3.4**: Fix RabbitMQ empty `securityContext`
  - In `rabbitmq/core/deployment.yaml:21`, remove the empty `securityContext:` line
  - Let the Kustomize JSON patch inject the complete context
  - Rationale: Eliminates a confusing null field that suggests incomplete hardening

---

### Phase 4: Validation & Rollout

- [ ] **Task 4.1**: Run updated script and verify zero false positives on rendered scan
  - Execute `./test-security-app.sh`
  - Confirm `trivy-rendered.sarif` contains **zero** KSV-0014 and KSV-0118 findings
  - Confirm `trivy-report.sarif` (raw scan) still contains expected findings (for backward compatibility)
  - Rationale: Validates the core objective—rendered scanning eliminates false positives

- [ ] **Task 4.2**: Verify raw scan still serves its purpose
  - Confirm raw `trivy fs` scan continues to detect issues in files **not** covered by Kustomize patches
  - Example: a new Deployment missing from `kustomization.yaml` resources list
  - Rationale: Raw scanning still provides early feedback for unpatched manifests

- [ ] **Task 4.3**: Update CI integration (if applicable)
  - If GitLab CI uses this script, update the artifact collection to include `trivy-rendered.sarif`
  - Configure GitLab's security dashboard to ingest the rendered SARIF as the authoritative source
  - Rationale: CI must reflect the new scanning strategy

- [ ] **Task 4.4**: Document the dual-scan strategy
  - Add a `## Scanning Strategy` section to `README.md` explaining:
    - Raw scan = early feedback on source files
    - Rendered scan = authoritative validation of deployed state
    - Kustomize patches are the source of truth for security hardening
  - Rationale: Future maintainers must understand why two Trivy scans exist

---

## Expected Outcomes

| Metric | Before | After |
|--------|--------|-------|
| False positives (K8s misconfigs) | **7 (100%)** | **0** |
| Trivy execution time | ~3x (triple run) | ~1x (single run + render) |
| Reproducibility | None (`:latest` tags) | Full (pinned versions) |
| Authoritative security gate | Raw files | Rendered manifests |
| Report artifact hygiene | Risky (no `.gitignore`) | Safe (`.gitignore` enforced) |

---

## Risk Assessment

| Risk | Likelihood | Mitigation |
|------|------------|------------|
| `kustomize` not available in CI | Medium | Fallback to `kubectl kustomize`; document prerequisites |
| Kustomize build fails on complex patches | Low | Task 1.2 validates build before scan implementation |
| Developers confused by two SARIF files | Medium | Task 4.4 documents strategy; naming convention (`trivy-report` vs `trivy-rendered`) clarifies purpose |
| Pinned images become outdated | Low | Document update cadence (quarterly or on CVE notification) |

---

## Definition of Done

- [ ] `./test-security-app.sh` executes successfully end-to-end
- [ ] `trivy-rendered.sarif` is generated and contains zero KSV-0014/KSV-0118 false positives
- [ ] All image tags are pinned to specific versions
- [ ] `.gitignore` excludes all report artifacts
- [ ] `.trivyignore` exists with documented suppressions
- [ ] `rabbitmq/core/deployment.yaml` has no empty `securityContext:` key
- [ ] `README.md` documents the dual-scan strategy
- [ ] CI pipeline (if applicable) collects `trivy-rendered.sarif`
