#!/usr/bin/env bash
set -Eeuo pipefail

kubectl get kustomizations -n flux-system
kubectl get helmreleases -A
kubectl get deployments -A
