#!/usr/bin/env bash
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib/scanners/common.sh
source "${ROOT_DIR}/scripts/lib/scanners/common.sh"
# shellcheck source=scripts/lib/scanners/sca.sh
source "${ROOT_DIR}/scripts/lib/scanners/sca.sh"
# shellcheck source=scripts/lib/scanners/sbom.sh
source "${ROOT_DIR}/scripts/lib/scanners/sbom.sh"
# shellcheck source=scripts/lib/scanners/secrets.sh
source "${ROOT_DIR}/scripts/lib/scanners/secrets.sh"
# shellcheck source=scripts/lib/scanners/iac.sh
source "${ROOT_DIR}/scripts/lib/scanners/iac.sh"
# shellcheck source=scripts/lib/scanners/image.sh
source "${ROOT_DIR}/scripts/lib/scanners/image.sh"

[[ "${1:-}" == "scan" ]] || { echo "Usage: scripts/homelab security scan [scanner]" >&2; exit 2; }
shift
case "${1:-}" in
  trivy) scan_trivy ;;
  kustomize) scan_kustomize ;;
  grype) scan_grype ;;
  gitleaks) scan_gitleaks ;;
  semgrep) scan_semgrep ;;
  syft) scan_syft ;;
  checkov) scan_checkov ;;
  image) shift; scan_image "$@" ;;
  validate) validate_reports ;;
  "")
    scan_trivy || SCAN_STATUS=1
    scan_kustomize || SCAN_STATUS=1
    scan_grype || SCAN_STATUS=1
    scan_gitleaks || SCAN_STATUS=1
    scan_semgrep || SCAN_STATUS=1
    scan_checkov || SCAN_STATUS=1
    scan_syft || SCAN_STATUS=1
    validate_reports || SCAN_STATUS=1
    exit "${SCAN_STATUS}"
    ;;
  *) echo "Unknown scanner: $1" >&2; exit 2 ;;
esac
