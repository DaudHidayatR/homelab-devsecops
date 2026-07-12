# Project Guidance

## Deployment ownership
- Flux owns ongoing deployment. Reconcile `infrastructure` before `apps`; never directly apply those trees as a Flux fallback.
- `clusters/kind/infrastructure.yaml` and `clusters/kind/apps.yaml` are the deployment aggregates.
- `CLUSTER_NAME` is the only cluster identity; derive the context as `kind-${CLUSTER_NAME}`.

## Generated artifacts
- Scanner reports and SBOM files are generated evidence. Do not treat file existence as scanner success; validate scanner exit status and SARIF invocation status.
- Do not hand-edit generated scan artifacts.

## Secrets and destructive operations
- Never commit credentials or interpolate secrets into shell source. Pass secret data through environment, argv, or stdin.
- Preserve OpenBao CLI arguments through `openbao::exec`; do not add remote `sh -c` command strings.
- Before deleting or rebuilding a cluster, validate and atomically back up the Tailscale operator identity. Restore it before starting the operator.
- Git-history cleanup rewrites shared history. Rotate credentials first and use only `scripts/git/auto-purge-secret.sh` with reviewed configuration.

## Knowledge sources
- `raw/` is immutable source material; never modify it.
- `wiki/` is maintained knowledge. Keep `wiki/index.md` as the catalog, `wiki/log.md` append-only, and claims traceable to source files.
