#!/usr/bin/env bash
# SCA scanners. Requires common.sh.
scan_trivy() {
  run_scanner "Trivy (JSON)" "$TRIVY_IMAGE" \
    fs --scanners vuln,secret,misconfig,license \
    --severity "$SEVERITY" --format json --ignore-unfixed \
    --output /out/trivy-report.json /src
  local trivy_status=$?

  if [ "$trivy_status" -ne 0 ]; then
    log_warn "Skipping remaining Trivy formats because Trivy initialization failed during JSON scan."
    write_skipped_report trivy-report.sarif "Trivy (SARIF)" "$trivy_status" \
      "Trivy JSON scan failed first; avoiding repeated DB/image download attempts." \
      "$RUNTIME" run --rm "$TRIVY_IMAGE" fs --format sarif --output /out/trivy-report.sarif /src
    write_skipped_report trivy-report.txt "Trivy (Table)" "$trivy_status" \
      "Trivy JSON scan failed first; avoiding repeated DB/image download attempts." \
      "$RUNTIME" run --rm "$TRIVY_IMAGE" fs --format table --output /out/trivy-report.txt /src
    return "${trivy_status}"
  fi

  run_scanner "Trivy (SARIF)" "$TRIVY_IMAGE" \
    fs --scanners vuln,secret,misconfig,license \
    --severity "$SEVERITY" --format sarif --ignore-unfixed \
    --output /out/trivy-report.sarif /src || trivy_status=1

  run_scanner "Trivy (Table)" "$TRIVY_IMAGE" \
    fs --scanners vuln,secret,misconfig,license \
    --severity "$SEVERITY" --format table --ignore-unfixed --dependency-tree \
    --output /out/trivy-report.txt /src || trivy_status=1
  return "${trivy_status}"
}

scan_grype() {
  run_scanner "Grype" "$GRYPE_IMAGE" \
    dir:/src -o json=/out/grype-report.json
}
