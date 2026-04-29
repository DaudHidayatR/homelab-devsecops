#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"


TRIVY_IMAGE="${TRIVY_IMAGE:-ghcr.io/aquasecurity/trivy:latest}"
SEMGREP_IMAGE="${SEMGREP_IMAGE:-docker.io/semgrep/semgrep:latest}"
SYFT_IMAGE="${SYFT_IMAGE:-docker.io/anchore/syft:latest}"
GITLEAKS_IMAGE="${GITLEAKS_IMAGE:-docker.io/zricethezav/gitleaks:latest}"
GRYPE_IMAGE="${GRYPE_IMAGE:-docker.io/anchore/grype:latest}"

FAILURES=0
RUNTIME=""
VOLUME_SUFFIX=""

detect_runtime() {
  if command -v podman >/dev/null 2>&1; then
    RUNTIME="podman"
    VOLUME_SUFFIX=":Z"
  elif command -v docker >/dev/null 2>&1; then
    RUNTIME="docker"
    VOLUME_SUFFIX=""
  else
    echo "Error: neither podman nor docker is installed." >&2
    exit 1
  fi
}

ensure_image() {
  local image="$1"
  if "$RUNTIME" image inspect "$image" >/dev/null 2>&1; then
    return 0
  fi
  echo "Pulling $image ..."
  "$RUNTIME" pull "$image"
}

run_scan() {
  local title="$1"
  local image="$2"
  shift 2

  echo ""
  echo "==> $title"

  if ensure_image "$image" && "$RUNTIME" run --rm \
    --memory=4g --cpus=2 \
    -v "$PWD:/project${VOLUME_SUFFIX}" \
    -w /project \
    "$image" \
    "$@"; then
    echo "OK: $title"
  else
    echo "FAILED: $title" >&2
    FAILURES=$((FAILURES + 1))
  fi
}

detect_runtime

echo "NOTE: This script is a local fallback when GitLab CI is unavailable."
echo "Reports are also generated automatically in the CI pipeline."
echo ""
echo "Using container runtime: $RUNTIME"
echo "Generating comprehensive security scan and SBOM reports..."
echo ""

# ─── 1. DEPENDENCY & VULNERABILITY SCANNING ───
# Trivy requires one format per invocation. We run three times to get
# JSON (programmatic), SARIF (GitLab security dashboard), and Table (human-readable).

run_scan "1a. Trivy vulnerability scan (JSON)..." "$TRIVY_IMAGE" \
  fs \
  --scanners vuln,secret,misconfig,license \
  --severity HIGH,CRITICAL \
  --ignore-unfixed \
  --dependency-tree \
  --format json \
  --output trivy-report.json \
  .

run_scan "1b. Trivy vulnerability scan (SARIF)..." "$TRIVY_IMAGE" \
  fs \
  --scanners vuln,secret,misconfig,license \
  --severity HIGH,CRITICAL \
  --ignore-unfixed \
  --format sarif \
  --output trivy-report.sarif \
  .

run_scan "1c. Trivy vulnerability scan (Table)..." "$TRIVY_IMAGE" \
  fs \
  --scanners vuln,secret,misconfig,license \
  --severity HIGH,CRITICAL \
  --ignore-unfixed \
  --dependency-tree \
  --format table \
  --output trivy-report.txt \
  .

run_scan "2. Grype alternative vulnerability scan..." "$GRYPE_IMAGE" \
  dir:/project \
  -o json=/project/grype-report.json

# ─── 2. RENDERED MANIFEST SCAN ───
# Kustomize builds the final manifests (including patches), then Trivy scans
# the rendered output. This eliminates false positives from raw-file scanning
# where securityContext patches have not yet been applied.

echo ""
echo "==> 3. Trivy scan of rendered Kustomize manifests..."

if command -v kustomize >/dev/null 2>&1; then
  KUSTOMIZE_CMD="kustomize build"
elif kubectl kustomize --help >/dev/null 2>&1; then
  KUSTOMIZE_CMD="kubectl kustomize"
else
  echo "WARNING: neither kustomize nor kubectl kustomize available; skipping rendered manifest scan." >&2
  KUSTOMIZE_CMD=""
fi

if [ -n "$KUSTOMIZE_CMD" ]; then
  RENDERED_FILE="${SCRIPT_DIR}/.rendered-manifests.yaml"
  if $KUSTOMIZE_CMD "$SCRIPT_DIR" > "$RENDERED_FILE"; then
    if ensure_image "$TRIVY_IMAGE" && "$RUNTIME" run --rm \
      --memory=2g --cpus=1 \
      -v "${SCRIPT_DIR}:/project${VOLUME_SUFFIX}" \
      -w /project \
      "$TRIVY_IMAGE" \
      config \
      --misconfig-scanners kubernetes \
      --severity HIGH,CRITICAL \
      --format sarif \
      --output /project/trivy-rendered.sarif \
      /project/.rendered-manifests.yaml; then
      echo "OK: Rendered manifest scan"
    else
      echo "FAILED: Rendered manifest scan" >&2
      FAILURES=$((FAILURES + 1))
    fi
  else
    echo "FAILED: kustomize build failed" >&2
    FAILURES=$((FAILURES + 1))
  fi
  rm -f "$RENDERED_FILE"
fi

# ─── 3. SECRET SCANNING ───

run_scan "4. GitLeaks secret detection..." "$GITLEAKS_IMAGE" \
  detect \
  --source /project \
  --verbose \
  --report-format json \
  --report-path /project/gitleaks-report.json

# ─── 4. SAST (STATIC ANALYSIS) ───
# NOTE: Semgrep K8s rules (yaml.kubernetes.security.*) produce false positives
# on raw YAML because they cannot resolve Kustomize patches. The rendered
# manifest scan (trivy-rendered.sarif) is the authoritative K8s validator.
# We explicitly exclude the two noisy K8s rules while keeping all other
# Semgrep rules active for shell-script and general security coverage.

EXCLUDE_K8S="--exclude-rule=yaml.kubernetes.security.run-as-non-root.run-as-non-root --exclude-rule=yaml.kubernetes.security.allow-privilege-escalation-no-securitycontext.allow-privilege-escalation-no-securitycontext"

run_scan "5a. Semgrep SAST scan (JSON)..." "$SEMGREP_IMAGE" \
  semgrep scan \
  --config p/default \
  --config p/secrets \
  --config p/supply-chain \
  $EXCLUDE_K8S \
  --metrics=off \
  --json \
  --output semgrep-report.json \
  .

run_scan "5b. Semgrep SAST scan (SARIF)..." "$SEMGREP_IMAGE" \
  semgrep scan \
  --config p/default \
  --config p/secrets \
  --config p/supply-chain \
  $EXCLUDE_K8S \
  --metrics=off \
  --sarif \
  --output semgrep-report.sarif \
  .

run_scan "5c. Semgrep SAST scan (Text)..." "$SEMGREP_IMAGE" \
  semgrep scan \
  --config p/default \
  --config p/secrets \
  --config p/supply-chain \
  $EXCLUDE_K8S \
  --metrics=off \
  --output semgrep-report.txt \
  .

# ─── 5. SBOM GENERATION ───

run_scan "6a. SBOM SPDX JSON (Syft)..." "$SYFT_IMAGE" \
  /project \
  -o spdx-json=/project/sbom-spdx.json

run_scan "6b. SBOM CycloneDX JSON (Syft)..." "$SYFT_IMAGE" \
  /project \
  -o cyclonedx-json=/project/sbom-cyclonedx.json

echo ""
echo "═════════════════════════════════════════════════════════════"
echo "Generated reports:"
echo "═════════════════════════════════════════════════════════════"

for file in \
  trivy-report.json \
  trivy-report.sarif \
  trivy-report.txt \
  trivy-rendered.sarif \
  grype-report.json \
  gitleaks-report.json \
  semgrep-report.json \
  semgrep-report.sarif \
  semgrep-report.txt \
  sbom-spdx.json \
  sbom-cyclonedx.json
do
  if [ -f "$file" ]; then
    size=$(du -h "$file" | cut -f1)
    echo "  ✓ $file ($size)"
  else
    echo "  ✗ missing: $file"
  fi
done

echo ""
if [ "$FAILURES" -gt 0 ]; then
  echo "Completed with $FAILURES failed step(s)." >&2
  exit 1
fi

echo "All scan steps completed successfully."
