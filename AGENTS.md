# Project Guidance

## Deployment ownership
- Flux owns ongoing deployment. Reconcile the ordered layers under `kubernetes/clusters/homelab/flux/kustomizations/` (bootstrap, cluster-resources, platform, openbao-config, cluster-policies, operations, apps); never directly apply those trees as a Flux fallback.
- `kubernetes/clusters/homelab/` is the desired-state root; the seven layer Kustomizations above are the deployment units.
- `CLUSTER_NAME` is the only cluster identity; derive the context as `kind-${CLUSTER_NAME}`.

## Generated artifacts
- Scanner reports and SBOM files are generated evidence. Do not treat file existence as scanner success; validate scanner exit status and SARIF invocation status.
- Do not hand-edit generated scan artifacts.

## Secrets and destructive operations
- Never commit credentials or interpolate secrets into shell source. Pass secret data through environment, argv, or stdin.
- Preserve OpenBao CLI arguments through `openbao::exec`; do not add remote `sh -c` command strings.
- Before deleting or rebuilding a cluster, validate and atomically back up the Tailscale operator identity. Restore it before starting the operator.
- Git-history cleanup is unsupported until a reviewed implementation is added. Rotate or revoke exposed credentials before any history rewrite.

## Knowledge sources
- `raw/` is immutable source material; never modify it.
- Compiled knowledge belongs in `document-project/web-documentasi/devsecops-homelab/template-wiki`; operational truth remains in this repository’s READMEs, manifests, scripts, and workflows. Keep claims traceable through the destination vault’s `Raw/Sources/` layer.
