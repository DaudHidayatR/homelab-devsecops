#!/usr/bin/env bash
set -eo pipefail

echo "=== Destroying kind cluster (rootless) ==="
kind delete cluster --name rootless-mesh

echo "=== Teardown Complete! ==="
