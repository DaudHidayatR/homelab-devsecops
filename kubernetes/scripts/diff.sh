#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
kubectl diff -k "${ROOT_DIR}/kubernetes/clusters/homelab" "$@"
