#!/usr/bin/env bash
# Shared OpenBao helpers for infra/kind scripts.

if [[ -n "${KIND_OPENBAO_SH_LOADED:-}" ]]; then
  return 0
fi
KIND_OPENBAO_SH_LOADED=1

# shellcheck source=scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
# shellcheck source=scripts/lib/kubernetes.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/kubernetes.sh"

: "${OPENBAO_NAMESPACE:=openbao}"
: "${OPENBAO_NS:=${OPENBAO_NAMESPACE}}"
: "${OPENBAO_POD:=openbao-0}"
: "${OPENBAO_ADDR:=http://127.0.0.1:8200}"
: "${OPENBAO_BACKUP_DIR:=${COMMON_REPO_ROOT}/.runtime-backups/openbao}"
: "${OPENBAO_INIT_JSON:=${COMMON_REPO_ROOT}/openbao-init.json}"
OPENBAO_BACKUP_DIR="$(common::abs_path "${OPENBAO_BACKUP_DIR}")"
OPENBAO_INIT_JSON="$(common::abs_path "${OPENBAO_INIT_JSON}")"

openbao::exec() {
  local token_export=""
  if [[ -n "${ROOT_TOKEN:-}" ]]; then
    token_export="export BAO_TOKEN='${ROOT_TOKEN}';"
  elif [[ -n "${OPENBAO_TOKEN:-}" ]]; then
    token_export="export BAO_TOKEN='${OPENBAO_TOKEN}';"
  fi

  kubectl exec -n "${OPENBAO_NS}" "${OPENBAO_POD}" -- sh -c "
    export BAO_ADDR='${OPENBAO_ADDR}'
    ${token_export}
    $*"
}

openbao::exec_quiet() {
  openbao::exec "$@" 2>/dev/null || true
}

openbao::load_root_token() {
  if [[ -n "${OPENBAO_TOKEN:-}" ]]; then
    printf '%s' "${OPENBAO_TOKEN}"
    return
  fi

  if [[ -f "${OPENBAO_BACKUP_DIR}/root-token.txt" ]]; then
    tr -d '\n' < "${OPENBAO_BACKUP_DIR}/root-token.txt"
    return
  fi

  if [[ -f "${OPENBAO_INIT_JSON}" ]]; then
    python3 - <<PY
import json
from pathlib import Path
print(json.loads(Path("${OPENBAO_INIT_JSON}").read_text())["root_token"], end="")
PY
    return
  fi

  common::die "OpenBao token not provided. Set OPENBAO_TOKEN, restore ${OPENBAO_BACKUP_DIR}/root-token.txt, or provide ${OPENBAO_INIT_JSON}."
}

openbao::pod_exists() {
  k8s::pod_exists "${OPENBAO_NS}" "${OPENBAO_POD}"
}

openbao::require_pod() {
  openbao::pod_exists || common::die "OpenBao pod '${OPENBAO_POD}' not found in namespace '${OPENBAO_NS}'. Deploy the cluster first: make up"
}

openbao::wait_ready() {
  local timeout="${1:-300s}"
  openbao::require_pod
  k8s::wait_pod_ready "${OPENBAO_NS}" "${OPENBAO_POD}" "${timeout}"
}

openbao::status_json() {
  openbao::exec_quiet "bao status -format=json"
}

openbao::is_initialized() {
  local status
  status="$(openbao::status_json | json::get_bool initialized False)"
  [[ "${status}" == "True" ]]
}

openbao::is_sealed() {
  local sealed
  sealed="$(openbao::status_json | json::get_bool sealed True)"
  [[ "${sealed}" == "True" ]]
}

openbao::login_root() {
  ROOT_TOKEN="$(openbao::load_root_token)"
  openbao::exec "bao login '${ROOT_TOKEN}'" >/dev/null
}

openbao::verify_token() {
  ROOT_TOKEN="${ROOT_TOKEN:-$(openbao::load_root_token)}"
  openbao::exec "bao token lookup >/dev/null"
}

openbao::auth_enabled() {
  local auth_path="$1"
  openbao::exec_quiet "bao auth list -format=json" | python3 -c "import json,sys; print('${auth_path}/' in json.load(sys.stdin))" 2>/dev/null | grep -q True
}

openbao::secrets_engine_enabled() {
  local engine_path="$1"
  openbao::exec_quiet "bao secrets list -format=json" | python3 -c "import json,sys; print('${engine_path}/' in json.load(sys.stdin))" 2>/dev/null | grep -q True
}

openbao::policy_exists() {
  local policy="$1"
  openbao::exec_quiet "bao policy read '${policy}' >/dev/null 2>&1"
}
