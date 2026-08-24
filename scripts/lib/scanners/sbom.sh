#!/usr/bin/env bash
# SBOM scanners. Requires common.sh.
scan_syft() {
  run_scanner "Syft (SPDX)" "$SYFT_IMAGE" \
    /src -o spdx-json=/out/sbom-spdx.json
  local syft_status=$?

  if [ "$syft_status" -ne 0 ]; then
    log_warn "Skipping remaining Syft formats because Syft failed during SPDX scan."
    write_skipped_report sbom-cyclonedx.json "Syft (CycloneDX)" "$syft_status" \
      "Syft SPDX scan failed first; avoiding repeated image/cataloger startup attempts." \
      "$RUNTIME" run --rm "$SYFT_IMAGE" /src -o cyclonedx-json=/out/sbom-cyclonedx.json
    return "${syft_status}"
  fi

  run_scanner "Syft (CycloneDX)" "$SYFT_IMAGE" \
    /src -o cyclonedx-json=/out/sbom-cyclonedx.json || syft_status=1
  return "${syft_status}"
}
