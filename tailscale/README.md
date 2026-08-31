# Tailscale operator credentials (SOPS flow)

The Flux-managed operator HelmRelease mounts Secret `tailscale/operator-oauth`.
The Secret is delivered out-of-band so no plaintext credential ever enters Git:

1. `cp tailscale/operator-oauth.local.example tailscale/operator-oauth.local.yaml`
   and fill in the real OAuth client values.
2. Replace the placeholder age recipient in `.sops.yaml` with the real
   recipient that owns the homelab recovery material.
3. `make tailscale-encrypt` — SOPS encrypts the local file into
   `tailscale/operator-oauth.enc.yaml` (the only credential file in Git).
4. `make up` decrypts it at deploy time (`sops -d`) and applies the Secret
   before the platform layer reconciles. Bootstrap fails if neither this file nor
   both environment credentials are usable.

For a one-time first bootstrap, `TAILSCALE_CLIENT_ID` and
`TAILSCALE_CLIENT_SECRET` may create the Secret directly. That fallback does not
create durable encrypted recovery material; complete steps 1–3 immediately after
bootstrap.

`sops-verify` re-checks that the committed file decrypts cleanly.
`scripts/check_sops_encrypted.py` (CI) rejects plaintext and placeholder SOPS
material. Plaintext files (`*.local.yaml`) are gitignored.
