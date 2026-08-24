#!/usr/bin/env bash
# Container image scanner entrypoint.
scan_image() {
  local image="${1:?image reference required}"
  run_scanner "Trivy image" "$TRIVY_IMAGE" image --severity "$SEVERITY" --format json --output /out/trivy-image-report.json "$image"
}
