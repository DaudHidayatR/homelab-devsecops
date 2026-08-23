#!/usr/bin/env bash
# Security Scan Orchestrator
# Local script for running the full security scanner suite via containers.
#
# Usage:
#   scripts/homelab security scan              # Run all scanners
#   scripts/homelab security scan trivy        # Run Trivy only
#   scripts/homelab security scan validate     # Validate report files only
#
# Environment:
#   SCAN_ROOT         — project directory to scan (default: this infra/kind directory)
#   SCAN_OUTPUT       — directory for generated reports (default: this infra/kind directory)
#   SCAN_RUNTIME_ARGS — extra Docker/Podman flags, for example: --dns 1.1.1.1
#   TRIVY_IMAGE       — Trivy container image
#   GRYPE_IMAGE       — Grype container image
#   GITLEAKS_IMAGE    — Gitleaks container image
#   SEMGREP_IMAGE     — Semgrep container image
#   SYFT_IMAGE        — Syft container image
#   CHECKOV_IMAGE     — Checkov container image
#   SEVERITY          — Severity threshold (default: HIGH,CRITICAL)

set -uo pipefail

# ─── CONFIGURATION ───
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
cd "$PROJECT_ROOT" || exit 1

# Source config.env (required — single source of truth)
if [ -f "$PROJECT_ROOT/config.env" ]; then
  # shellcheck source=/dev/null
  . "$PROJECT_ROOT/config.env"
else
  echo "ERROR: config.env not found. It is the single source of truth for scanner versions." >&2
  exit 1
fi

SCAN_TARGET="${SCAN_ROOT:-$PROJECT_ROOT}"
SCAN_TARGET="$(cd "$SCAN_TARGET" && pwd)"
REPORT_DIR="${SCAN_OUTPUT:-$PROJECT_ROOT}"
mkdir -p "$REPORT_DIR"
REPORT_DIR="$(cd "$REPORT_DIR" && pwd)"

# Clean up stale output from previous runs (Checkov v3+ creates directories)
rm -rf "$REPORT_DIR/checkov-json" "$REPORT_DIR/checkov-sarif"

# Verify required variables are set after sourcing
: "${TRIVY_IMAGE:?}" "${GRYPE_IMAGE:?}" "${GITLEAKS_IMAGE:?}" "${SEMGREP_IMAGE:?}" "${SYFT_IMAGE:?}" "${CHECKOV_IMAGE:?}" "${SEVERITY:?}"

SEMGREP_RULESETS="${SEMGREP_RULESETS:-p/default,p/owasp-top-ten,p/cwe-top-25,p/security-audit,p/secrets,p/supply-chain,p/docker,p/kubernetes}"

# ─── LOGGING ───
log_info()  { printf '[INFO]  %s\n' "$*"; }
log_warn()  { printf '[WARN]  %s\n' "$*" >&2; }
log_error() { printf '[ERROR] %s\n' "$*" >&2; }
log_ok()    { printf '[OK]    %s\n' "$*"; }

# Detect container runtime
if command -v podman >/dev/null 2>&1; then
  RUNTIME=podman
  VOL_SUFFIX=":Z"
  if [ "${EUID:-$(id -u)}" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
    log_warn "Running Podman through sudo uses rootful networking; if registry/DNS lookups fail, retry without sudo or pass working DNS via SCAN_RUNTIME_ARGS."
  fi
elif command -v docker >/dev/null 2>&1; then
  RUNTIME=docker
  VOL_SUFFIX=""
else
  log_error "no container runtime (docker or podman) found."
  exit 1
fi

runtime_command() {
  RUNTIME_CMD=("$RUNTIME" run --rm)
  if [ -n "${SCAN_RUNTIME_ARGS:-}" ]; then
    # Intentional word splitting lets users pass runtime flags like: --dns 1.1.1.1
    # shellcheck disable=SC2206
    local runtime_args=( $SCAN_RUNTIME_ARGS )
    RUNTIME_CMD+=("${runtime_args[@]}")
  fi
  RUNTIME_CMD+=(
    -e "TRIVY_DB_REPOSITORY=${TRIVY_DB_REPOSITORY:-}"
    -v "${SCAN_TARGET}:/src${VOL_SUFFIX}"
    -v "${REPORT_DIR}:/out${VOL_SUFFIX}"
    -w /src
  )
}

json_escape() {
  local value="$1"
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\n'/\\n}
  value=${value//$'\r'/\\r}
  value=${value//$'\t'/\\t}
  printf '%s' "$value"
}

command_json_array() {
  local first=1
  local arg
  printf '['
  for arg in "$@"; do
    [ "$first" -eq 1 ] || printf ','
    printf '"%s"' "$(json_escape "$arg")"
    first=0
  done
  printf ']'
}

write_error_json() {
  local report="$1" scanner_name="$2" exit_code="$3"
  shift 3
  cat > "$REPORT_DIR/$report" <<EOF
{
  "schemaVersion": 1,
  "scanner": "$(json_escape "$scanner_name")",
  "status": "error",
  "exitCode": $exit_code,
  "target": "$(json_escape "$SCAN_TARGET")",
  "message": "Scanner failed before producing this report. This placeholder records the failure so downstream report collection is deterministic.",
  "command": $(command_json_array "$@")
}
EOF
}

write_error_sarif() {
  local report="$1" scanner_name="$2" exit_code="$3"
  shift 3
  cat > "$REPORT_DIR/$report" <<EOF
{
  "version": "2.1.0",
  "\$schema": "https://json.schemastore.org/sarif-2.1.0.json",
  "runs": [
    {
      "tool": {
        "driver": {
          "name": "$(json_escape "$scanner_name")",
          "rules": [
            {
              "id": "scanner-execution-failed",
              "name": "Scanner execution failed",
              "shortDescription": { "text": "Scanner failed before producing results" },
              "help": { "text": "Check container image availability, network/DNS access, scanner databases, and runtime permissions." }
            }
          ]
        }
      },
      "invocations": [
        {
          "executionSuccessful": false,
          "exitCode": $exit_code,
          "commandLine": "$(json_escape "$*")"
        }
      ],
      "results": [
        {
          "ruleId": "scanner-execution-failed",
          "level": "error",
          "message": { "text": "$(json_escape "$scanner_name") failed before producing this report." }
        }
      ]
    }
  ]
}
EOF
}

write_error_text() {
  local report="$1" scanner_name="$2" exit_code="$3"
  shift 3
  cat > "$REPORT_DIR/$report" <<EOF
$scanner_name failed before producing this report.

Status: error
Exit code: $exit_code
Target: $SCAN_TARGET
Command: $*

Check container image availability, network/DNS access, scanner databases, and runtime permissions.
EOF
}

write_error_report() {
  local report="$1" scanner_name="$2" exit_code="$3"
  shift 3
  [ -s "$REPORT_DIR/$report" ] && return 0
  case "$report" in
    *.sarif) write_error_sarif "$report" "$scanner_name" "$exit_code" "$@" ;;
    *.txt) write_error_text "$report" "$scanner_name" "$exit_code" "$@" ;;
    *) write_error_json "$report" "$scanner_name" "$exit_code" "$@" ;;
  esac
  log_warn "Wrote fallback error report: $report"
}

write_skipped_report() {
  local report="$1" scanner_name="$2" exit_code="$3" reason="$4"
  shift 4
  write_error_report "$report" "$scanner_name" "$exit_code" "$@" "skipped:" "$reason"
}

# ─── SCANNER RUNNER ───
run_scanner() {
  local name="$1"
  shift
  log_info "Running $name ..."
  runtime_command
  local cmd=("${RUNTIME_CMD[@]}" "$@")
  if "${cmd[@]}"; then
    log_ok "$name completed"
    return 0
  else
    local exit_code=$?
    log_warn "$name exited with non-zero code (findings or error) — report file will be validated below."
    case "$name" in
      "Trivy (JSON)") write_error_report trivy-report.json "$name" "$exit_code" "${cmd[@]}" ;;
      "Trivy (SARIF)") write_error_report trivy-report.sarif "$name" "$exit_code" "${cmd[@]}" ;;
      "Trivy (Table)") write_error_report trivy-report.txt "$name" "$exit_code" "${cmd[@]}" ;;
      "Kustomize (Trivy config)") write_error_report trivy-rendered.sarif "$name" "$exit_code" "${cmd[@]}" ;;
      "Grype") write_error_report grype-report.json "$name" "$exit_code" "${cmd[@]}" ;;
      "GitLeaks") write_error_report gitleaks-report.json "$name" "$exit_code" "${cmd[@]}" ;;
      "Semgrep (JSON)") write_error_report semgrep-report.json "$name" "$exit_code" "${cmd[@]}" ;;
      "Semgrep (SARIF)") write_error_report semgrep-report.sarif "$name" "$exit_code" "${cmd[@]}" ;;
      "Checkov Kubernetes (SARIF)") write_error_report checkov-report.sarif "$name" "$exit_code" "${cmd[@]}" ;;
      "Checkov Kubernetes (JSON)") write_error_report checkov-report.json "$name" "$exit_code" "${cmd[@]}" ;;
      "Syft (SPDX)") write_error_report sbom-spdx.json "$name" "$exit_code" "${cmd[@]}" ;;
      "Syft (CycloneDX)") write_error_report sbom-cyclonedx.json "$name" "$exit_code" "${cmd[@]}" ;;
    esac
    return "$exit_code"
  fi
}

# ─── VALIDATION ───
validate_reports() {
  log_info "═════════════════════════════════════════════════════════════"
  log_info "Validating report files in $REPORT_DIR ..."
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
    checkov-report.json
    checkov-report.sarif
    sbom-spdx.json
    sbom-cyclonedx.json
  )
  if [ -f "$SCAN_TARGET/kustomization.yaml" ] || [ -f "$SCAN_TARGET/kustomization.yml" ] || [ -f "$SCAN_TARGET/Kustomization" ]; then
    required+=(trivy-rendered.sarif)
  fi

  local failures=0
  local f
  for f in "${required[@]}"; do
    if [ -f "$REPORT_DIR/$f" ] && [ -s "$REPORT_DIR/$f" ]; then
      log_ok "$f"
    else
      log_error "missing or empty: $f"
      failures=$((failures + 1))
    fi
  done

  for f in "${required[@]}"; do
    [ -s "$REPORT_DIR/$f" ] || continue
    if ! python3 - "$REPORT_DIR/$f" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
if p.suffix not in {'.json', '.sarif'}:
    raise SystemExit(0)
data = json.loads(p.read_text())
if data.get('status') == 'error':
    raise SystemExit(1)
if any(inv.get('executionSuccessful') is False for run in data.get('runs', []) for inv in run.get('invocations', [])):
    raise SystemExit(1)
PY
    then
      log_error "scanner error artifact: $f"
      failures=$((failures + 1))
    fi
  done


  if [ "$failures" -gt 0 ]; then
    log_error "Report validation failed for $failures artifact(s)."
    return 1
  fi

  log_ok "All scan steps completed successfully."
  return 0
}
