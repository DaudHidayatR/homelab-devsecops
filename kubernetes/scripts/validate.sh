#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLUSTER_DIR="${ROOT_DIR}/kubernetes/clusters/homelab"

for overlay in \
  bootstrap \
  cluster-resources \
  platform \
  platform/openbao/configuration \
  operations \
  apps \
  flux \
  .; do
  kubectl kustomize "${CLUSTER_DIR}/${overlay}" >/dev/null
  printf 'valid: %s\n' "${overlay}"
done
