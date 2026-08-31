# Tailscale operator on the homelab cluster (Flux-managed)

The operator is deployed by Flux from this directory (HelmRelease
`tailscale-operator`, chart `tailscale-operator` 1.102.3 pinned in
`helmrelease.yaml`). The shell layer only verifies the rollout.

## Credentials

`operator-values.yaml` intentionally sets no OAuth credentials. The chart
mounts the pre-created Secret `operator-oauth` (CLIENT_ID_FILE /
CLIENT_SECRET_FILE). Deliver the Secret with SOPS — see
`tailscale/README.md` at the repo root for the one-time encryption flow.
