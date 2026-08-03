#!/usr/bin/env bash
# Secret and source scanners. Requires common.sh.
scan_gitleaks() {
  run_scanner "GitLeaks" "$GITLEAKS_IMAGE" \
    detect --source /src --report-format json --report-path /out/gitleaks-report.json -v
}

# ─── SEMGREP ARG BUILDER ───
build_semgrep_args() {
  SEMGREP_ARGS=(semgrep)

  IFS=',' read -ra rules <<< "$SEMGREP_RULESETS"
  for r in "${rules[@]}"; do
    r="${r//[[:space:]]/}"
    [ -n "$r" ] && SEMGREP_ARGS+=(--config "$r")
  done

  if [ -n "$(find "$SCAN_TARGET" -maxdepth 2 -name "*.py" -print -quit)" ]; then
    SEMGREP_ARGS+=(--config "p/python")
  fi
  if [ -n "$(find "$SCAN_TARGET" -maxdepth 2 \( -name "*.js" -o -name "*.ts" \) -print -quit)" ]; then
    SEMGREP_ARGS+=(--config "p/javascript" --config "p/typescript")
  fi


  SEMGREP_ARGS+=(--max-memory=4096 --metrics=off)
}

scan_semgrep() {
  build_semgrep_args

  run_scanner "Semgrep (JSON)" "$SEMGREP_IMAGE" \
    "${SEMGREP_ARGS[@]}" --json --output /out/semgrep-report.json /src
  local semgrep_status=$?

  if [ "$semgrep_status" -ne 0 ]; then
    log_warn "Skipping remaining Semgrep formats because Semgrep failed during JSON scan."
    write_skipped_report semgrep-report.sarif "Semgrep (SARIF)" "$semgrep_status" \
      "Semgrep JSON scan failed first; avoiding repeated image/ruleset download attempts." \
      "$RUNTIME" run --rm "$SEMGREP_IMAGE" semgrep --sarif --output /out/semgrep-report.sarif /src
    write_skipped_report semgrep-report.txt "Semgrep (Text)" "$semgrep_status" \
      "Semgrep JSON scan failed first; avoiding repeated image/ruleset download attempts." \
      "$RUNTIME" run --rm "$SEMGREP_IMAGE" semgrep --output /out/semgrep-report.txt /src
    return "${semgrep_status}"
  fi

  run_scanner "Semgrep (SARIF)" "$SEMGREP_IMAGE" \
    "${SEMGREP_ARGS[@]}" --sarif --output /out/semgrep-report.sarif /src || semgrep_status=1

  log_info "Running Semgrep (Text) ..."
  runtime_command
  local cmd=("${RUNTIME_CMD[@]}" "$SEMGREP_IMAGE" "${SEMGREP_ARGS[@]}" --text /src)
  if "${cmd[@]}" > "$REPORT_DIR/semgrep-report.txt" 2>&1; then
    log_ok "Semgrep (Text) completed"
  else
    local exit_code=$?
    log_warn "Semgrep (Text) exited with non-zero code (findings or error) — report file will be validated below."
    write_error_report semgrep-report.txt "Semgrep (Text)" "$exit_code" "${cmd[@]}"
    semgrep_status=1
  fi
  return "${semgrep_status}"
}
