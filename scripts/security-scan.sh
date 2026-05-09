#!/usr/bin/env bash
# Security Scan Orchestrator
# Local script for running the full security scanner suite via containers.
#
# Usage:
#   ./scripts/security-scan.sh              # Run all scanners
#   ./scripts/security-scan.sh trivy        # Run Trivy only
#   ./scripts/security-scan.sh validate     # Validate report files only
#
# Environment:
#   SCAN_ROOT      — project directory to scan (default: current directory)
#   TRIVY_IMAGE    — Trivy container image
#   GRYPE_IMAGE    — Grype container image
#   GITLEAKS_IMAGE — Gitleaks container image
#   SEMGREP_IMAGE  — Semgrep container image
#   SYFT_IMAGE     — Syft container image
#   SEVERITY       — Severity threshold (default: HIGH,CRITICAL)

set -uo pipefail

# ─── CONFIGURATION ───
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$PROJECT_ROOT" || exit 1

# Source config.env (required — single source of truth)
if [ -f "$PROJECT_ROOT/config.env" ]; then
  # shellcheck source=/dev/null
  . "$PROJECT_ROOT/config.env"
else
  echo "ERROR: config.env not found. It is the single source of truth for scanner versions." >&2
  exit 1
fi

# Verify required variables are set after sourcing
: "${TRIVY_IMAGE:?}" "${GRYPE_IMAGE:?}" "${GITLEAKS_IMAGE:?}" "${SEMGREP_IMAGE:?}" "${SYFT_IMAGE:?}" "${SEVERITY:?}"

SEMGREP_RULESETS="${SEMGREP_RULESETS:-p/default,p/owasp-top-ten,p/cwe-top-25,p/security-audit,p/secrets,p/supply-chain,p/docker,p/kubernetes}"
SEMGREP_EXCLUDE_RULES="${SEMGREP_EXCLUDE_RULES:-yaml.kubernetes.security.run-as-non-root.run-as-non-root,yaml.kubernetes.security.allow-privilege-escalation-no-securitycontext.allow-privilege-escalation-no-securitycontext}"

# Detect container runtime
if command -v podman >/dev/null 2>&1; then
  RUNTIME=podman
  VOL_SUFFIX=":Z"
elif command -v docker >/dev/null 2>&1; then
  RUNTIME=docker
  VOL_SUFFIX=""
else
  echo "ERROR: no container runtime (docker or podman) found." >&2
  exit 1
fi

# ─── LOGGING ───
log_info()  { printf '[INFO]  %s\n' "$*"; }
log_warn()  { printf '[WARN]  %s\n' "$*" >&2; }
log_error() { printf '[ERROR] %s\n' "$*" >&2; }
log_ok()    { printf '[OK]    %s\n' "$*"; }

# ─── SCANNER RUNNER ───
run_scanner() {
  local name="$1"
  shift
  log_info "Running $name ..."
  if "$RUNTIME" run --rm \
    -v "${PROJECT_ROOT}:/src${VOL_SUFFIX}" \
    -w /src \
    "$@"; then
    log_ok "$name completed"
  else
    log_warn "$name exited with non-zero code (findings or error) — report file will be validated below."
  fi
}

# ─── INDIVIDUAL SCANNERS ───
scan_trivy() {
  run_scanner "Trivy (JSON)" "$TRIVY_IMAGE" \
    fs --scanners vuln,secret,misconfig,license \
    --severity "$SEVERITY" --format json --ignore-unfixed \
    --output /src/trivy-report.json /src

  run_scanner "Trivy (SARIF)" "$TRIVY_IMAGE" \
    fs --scanners vuln,secret,misconfig,license \
    --severity "$SEVERITY" --format sarif --ignore-unfixed \
    --output /src/trivy-report.sarif /src

  run_scanner "Trivy (Table)" "$TRIVY_IMAGE" \
    fs --scanners vuln,secret,misconfig,license \
    --severity "$SEVERITY" --format table --ignore-unfixed --dependency-tree \
    --output /src/trivy-report.txt /src
}

scan_kustomize() {
  if [ ! -f "$PROJECT_ROOT/kustomization.yaml" ] && [ ! -f "$PROJECT_ROOT/kustomization.yml" ] && [ ! -f "$PROJECT_ROOT/Kustomization" ]; then
    log_warn "No kustomization file found; skipping rendered manifest scan."
    return 0
  fi

  log_info "Rendering kustomize manifests ..."
  local rendered="$PROJECT_ROOT/.rendered-manifests.yaml"
  if command -v kustomize >/dev/null 2>&1; then
    if ! kustomize build "$PROJECT_ROOT" > "$rendered" 2>/dev/null; then
      log_warn "Kustomize build failed; skipping rendered manifest scan."
      rm -f "$rendered"
      return 0
    fi
  elif command -v kubectl >/dev/null 2>&1; then
    if ! kubectl kustomize "$PROJECT_ROOT" > "$rendered" 2>/dev/null; then
      log_warn "kubectl kustomize failed; skipping rendered manifest scan."
      rm -f "$rendered"
      return 0
    fi
  else
    log_warn "Neither kustomize nor kubectl available; skipping rendered manifest scan."
    return 0
  fi

  run_scanner "Kustomize (Trivy config)" "$TRIVY_IMAGE" \
    config --severity "$SEVERITY" --format sarif \
    --output /src/trivy-rendered.sarif /src/.rendered-manifests.yaml

  rm -f "$rendered"
}

scan_grype() {
  run_scanner "Grype" "$GRYPE_IMAGE" \
    dir:/src -o json=/src/grype-report.json
}

scan_gitleaks() {
  run_scanner "GitLeaks" "$GITLEAKS_IMAGE" \
    detect --source /src --report-format json --report-path /src/gitleaks-report.json -v
}

# ─── SEMGREP ARG BUILDER ───
build_semgrep_args() {
  SEMGREP_ARGS=(semgrep)

  IFS=',' read -ra rules <<< "$SEMGREP_RULESETS"
  for r in "${rules[@]}"; do
    SEMGREP_ARGS+=(--config "$r")
  done

  if [ -n "$(find "$PROJECT_ROOT" -maxdepth 2 -name "*.py" -print -quit)" ]; then
    SEMGREP_ARGS+=(--config "p/python")
  fi
  if [ -n "$(find "$PROJECT_ROOT" -maxdepth 2 \( -name "*.js" -o -name "*.ts" \) -print -quit)" ]; then
    SEMGREP_ARGS+=(--config "p/javascript" --config "p/typescript")
  fi

  IFS=',' read -ra exclusions <<< "$SEMGREP_EXCLUDE_RULES"
  for e in "${exclusions[@]}"; do
    SEMGREP_ARGS+=(--exclude-rule="$e")
  done

  SEMGREP_ARGS+=(--max-memory=4096 --metrics=off)
}

scan_semgrep() {
  build_semgrep_args

  run_scanner "Semgrep (JSON)" "$SEMGREP_IMAGE" \
    "${SEMGREP_ARGS[@]}" --json --output /src/semgrep-report.json /src

  run_scanner "Semgrep (SARIF)" "$SEMGREP_IMAGE" \
    "${SEMGREP_ARGS[@]}" --sarif --output /src/semgrep-report.sarif /src

  run_scanner "Semgrep (Text)" "$SEMGREP_IMAGE" \
    "${SEMGREP_ARGS[@]}" --output /src/semgrep-report.txt /src
}

scan_syft() {
  run_scanner "Syft (SPDX)" "$SYFT_IMAGE" \
    /src -o spdx-json=/src/sbom-spdx.json

  run_scanner "Syft (CycloneDX)" "$SYFT_IMAGE" \
    /src -o cyclonedx-json=/src/sbom-cyclonedx.json
}

# ─── VALIDATION ───
validate_reports() {
  log_info "═════════════════════════════════════════════════════════════"
  log_info "Validating report files ..."
  log_info "═════════════════════════════════════════════════════════════"

  local required=(
    trivy-report.json
    trivy-report.sarif
    trivy-report.txt
    grype-report.json
    gitleaks-report.json
    semgrep-report.json
    semgrep-report.sarif
    semgrep-report.txt
    sbom-spdx.json
    sbom-cyclonedx.json
  )

  local missing=0
  for f in "${required[@]}"; do
    if [ -f "$PROJECT_ROOT/$f" ] && [ -s "$PROJECT_ROOT/$f" ]; then
      log_ok "$f ($(du -h "$PROJECT_ROOT/$f" | cut -f1))"
    else
      log_error "missing or empty: $f"
      missing=$((missing + 1))
    fi
  done

  if [ -f "$PROJECT_ROOT/kustomization.yaml" ] || [ -f "$PROJECT_ROOT/kustomization.yml" ] || [ -f "$PROJECT_ROOT/Kustomization" ]; then
    if [ -f "$PROJECT_ROOT/trivy-rendered.sarif" ] && [ -s "$PROJECT_ROOT/trivy-rendered.sarif" ]; then
      log_ok "trivy-rendered.sarif"
    else
      log_error "missing or empty: trivy-rendered.sarif"
      missing=$((missing + 1))
    fi
  fi

  if [ "$missing" -gt 0 ]; then
    log_error "Completed with $missing missing report file(s)."
    return 1
  fi

  log_ok "All scan steps completed successfully."
  return 0
}

# ─── MAIN ───
case "${1:-}" in
  trivy)     scan_trivy ;;
  kustomize) scan_kustomize ;;
  grype)     scan_grype ;;
  gitleaks)  scan_gitleaks ;;
  semgrep)   scan_semgrep ;;
  syft)      scan_syft ;;
  validate)  validate_reports; exit $? ;;
  "")
    scan_trivy
    scan_kustomize
    scan_grype
    scan_gitleaks
    scan_semgrep
    scan_syft
    validate_reports
    exit $?
    ;;
  *)
    echo "Usage: $0 [trivy|grype|gitleaks|semgrep|syft|kustomize|validate]" >&2
    exit 1
    ;;
esac
