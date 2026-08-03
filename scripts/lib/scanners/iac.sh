#!/usr/bin/env bash
# IaC scanners. Requires common.sh.
scan_kustomize() {
  if [ ! -f "$SCAN_TARGET/kustomization.yaml" ] && [ ! -f "$SCAN_TARGET/kustomization.yml" ] && [ ! -f "$SCAN_TARGET/Kustomization" ]; then
    log_warn "No kustomization file found; skipping rendered manifest scan."
    return 0
  fi

  log_info "Rendering kustomize manifests ..."
  local rendered="$REPORT_DIR/.rendered-manifests.yaml"
  if command -v kustomize >/dev/null 2>&1; then
    if ! kustomize build "$SCAN_TARGET" > "$rendered" 2>/dev/null; then
      log_error "Kustomize build failed."
      rm -f "$rendered"
      return 1
    fi
  elif command -v kubectl >/dev/null 2>&1; then
    if ! kubectl kustomize "$SCAN_TARGET" > "$rendered" 2>/dev/null; then
      log_error "kubectl kustomize failed."
      rm -f "$rendered"
      return 1
    fi
  else
    log_error "Neither kustomize nor kubectl is available for rendered manifest scanning."
    return 1
  fi

  run_scanner "Kustomize (Trivy config)" "$TRIVY_IMAGE" \
    config --severity "$SEVERITY" --format sarif \
    --output /out/trivy-rendered.sarif /out/.rendered-manifests.yaml

  rm -f "$rendered"
}

scan_checkov() {
  local checkov_status=0
  run_scanner "Checkov Kubernetes (SARIF)" "$CHECKOV_IMAGE" \
    -d /src --framework kubernetes --quiet \
    -o sarif --output-file-path /out/checkov-sarif || checkov_status=1
  if [ -f "$REPORT_DIR/checkov-sarif/results_sarif.sarif" ]; then
    mv "$REPORT_DIR/checkov-sarif/results_sarif.sarif" "$REPORT_DIR/checkov-report.sarif"
    rm -rf "$REPORT_DIR/checkov-sarif"
  fi

  run_scanner "Checkov Kubernetes (JSON)" "$CHECKOV_IMAGE" \
    -d /src --framework kubernetes --quiet \
    -o json --output-file-path /out/checkov-json || checkov_status=1
  if [ -f "$REPORT_DIR/checkov-json/results_json.json" ]; then
    mv "$REPORT_DIR/checkov-json/results_json.json" "$REPORT_DIR/checkov-report.json"
    rm -rf "$REPORT_DIR/checkov-json"
  fi
  return "${checkov_status}"
}
