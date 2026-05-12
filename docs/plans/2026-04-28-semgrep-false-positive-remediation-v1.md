# Semgrep False Positive Remediation Plan

## Objective

Reduce Semgrep scan noise and false positives while preserving security coverage for the IaC-only repository. All 6 current Semgrep findings are K8s false positives caused by the same raw-file vs Kustomize-patch gap as Trivy. These cannot be eliminated without breaking the safety net for unpatched deployments.

## Context

- Repository contains only YAML manifests, shell scripts, and documentation
- No application code (Go, Python, JavaScript, etc.)
- Semgrep loads 1,130 rules but only 16 are K8s-related; only 2 of those fire
- Rule packs `p/owasp-top-ten`, `p/cwe-top-25`, `p/command-injection`, `p/xss`, `p/sql-injection` are completely irrelevant for IaC
- `p/default` is an umbrella pack that already includes most of the above
- `p/secrets` overlaps with GitLeaks but catches different secret patterns

## Implementation Plan

### Phase 1: Add `.semgrepignore`

- [ ] Create `.semgrepignore` excluding non-deployable directories
  - `wiki/`, `raw/`, `plans/`, `docs/`, `scripts/`
  - Rationale: These contain documentation, planning files, and helper scripts, not infrastructure code
  - Also exclude `*.md`, `*.txt` files at root level

### Phase 2: Deduplicate Semgrep Rule Packs

- [ ] Replace 9 overlapping rule packs with focused selection:
  - `p/default` (umbrella: covers OWASP, CWE, CI, injection, transport, XSS, SQLi)
  - `p/secrets` (complements GitLeaks with different detection patterns)
  - `p/supply-chain` (dependency confusion / typosquatting)
  - Rationale: Eliminates redundant rule evaluation; `p/default` already includes 7 of the 9 packs
  - **Important**: Keep K8s rules active — they serve as safety net for unpatched deployments

### Phase 3: Document Expected False Positives

- [ ] Add inline comment in `test-security-app.sh` near Semgrep invocation:
  - Explain that K8s findings in raw files are expected false positives
  - Point to Kustomize patches as the authoritative hardening source
  - Reference rendered Trivy scan as the authoritative K8s validation
- [ ] Update `README.md` security scanning section to mention Semgrep K8s false positives

### Phase 4: Validate

- [ ] Run `./test-security-app.sh` and verify:
  - Semgrep scan completes successfully
  - Rule load count drops from ~1,130 to ~600-800
  - K8s findings still present (confirming safety net intact)
  - No findings in excluded directories

## Design Decision: Do NOT Suppress K8s Rules

Suppressing `yaml.kubernetes.security.*` rules via `--exclude-rule` or `.semgrepignore` would:
- Eliminate the 6 false positives
- Also eliminate detection if a Deployment is accidentally removed from `kustomization.yaml` patches
- Create a silent failure mode during IaC refactoring

**Decision**: Accept the 6 false positives as inherent cost of defense-in-depth. The rendered Trivy scan (`trivy-rendered.sarif`) provides the authoritative K8s validation.

## Expected Outcomes

| Metric | Before | After |
|--------|--------|-------|
| Semgrep rules loaded | ~1,130 | ~600-800 |
| Rule packs declared | 9 | 3 |
| Scan time | Baseline | ~30% faster |
| K8s false positives | 6 | 6 (accepted) |
| Coverage of non-K8s issues | Full | Same |
| Safety net for unpatched deployments | Yes | Yes |
