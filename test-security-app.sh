#!/usr/bin/env bash

set -uo pipefail

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

echo "DEPRECATED: This script has been replaced by GitLab CI automation."
echo "Reports are now generated automatically in the CI pipeline."
echo ""
echo "Using container runtime: $RUNTIME"
echo "Generating comprehensive security scan and SBOM reports..."
echo ""

# ─── 1. DEPENDENCY & VULNERABILITY SCANNING ───

run_scan "1a. Trivy vulnerability scan (JSON)..." "$TRIVY_IMAGE" \
  fs \
  --scanners vuln,secret,config,license \
  --severity HIGH,CRITICAL \
  --ignore-unfixed \
  --dependency-tree \
  --format json \
  --output trivy-report.json \
  .

run_scan "1b. Trivy vulnerability scan (Table)..." "$TRIVY_IMAGE" \
  fs \
  --scanners vuln,secret,config,license \
  --severity HIGH,CRITICAL \
  --ignore-unfixed \
  --dependency-tree \
  --format table \
  --output trivy-report.txt \
  .

run_scan "1c. Trivy vulnerability scan (SARIF)..." "$TRIVY_IMAGE" \
  fs \
  --scanners vuln,secret,config \
  --severity HIGH,CRITICAL \
  --ignore-unfixed \
  --format sarif \
  --output trivy-report.sarif \
  .

run_scan "2. Grype alternative vulnerability scan..." "$GRYPE_IMAGE" \
  dir:/project \
  -o json=/project/grype-report.json

# ─── 2. SECRET SCANNING ───

run_scan "3. GitLeaks secret detection..." "$GITLEAKS_IMAGE" \
  detect \
  --source /project \
  --verbose \
  --report-format json \
  --report-path /project/gitleaks-report.json

# ─── 3. SAST (STATIC ANALYSIS) ───

run_scan "4a. Semgrep SAST scan (JSON)..." "$SEMGREP_IMAGE" \
  semgrep scan \
  --config p/default \
  --config p/owasp-top-ten \
  --config p/cwe-top-25 \
  --config p/ci \
  --config p/secrets \
  --config p/supply-chain \
  --config p/command-injection \
  --config p/insecure-transport \
  --config p/xss \
  --config p/sql-injection \
  --metrics=off \
  --json \
  --output semgrep-report.json \
  .

run_scan "4b. Semgrep SAST scan (SARIF)..." "$SEMGREP_IMAGE" \
  semgrep scan \
  --config p/default \
  --config p/owasp-top-ten \
  --config p/cwe-top-25 \
  --config p/ci \
  --config p/secrets \
  --config p/supply-chain \
  --metrics=off \
  --sarif \
  --output semgrep-report.sarif \
  .

run_scan "4c. Semgrep SAST scan (Text)..." "$SEMGREP_IMAGE" \
  semgrep scan \
  --config p/default \
  --config p/owasp-top-ten \
  --config p/cwe-top-25 \
  --metrics=off \
  --output semgrep-report.txt \
  .

# ─── 4. SBOM GENERATION ───

run_scan "5a. SBOM SPDX JSON (Syft)..." "$SYFT_IMAGE" \
  /project \
  -o spdx-json=/project/sbom-spdx.json

run_scan "5b. SBOM CycloneDX JSON (Syft)..." "$SYFT_IMAGE" \
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