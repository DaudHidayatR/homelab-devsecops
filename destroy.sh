#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.env"

echo "=== Destroying kind cluster (rootless) ==="
kind delete cluster --name "$CLUSTER_NAME"

echo "=== Teardown Complete! ==="
