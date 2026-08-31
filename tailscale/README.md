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
   before the platform layer reconciles.

`sops-verify` re-checks that the committed file decrypts cleanly.
`scripts/check_sops_encrypted.py` (CI) fails if committed credential material
is not SOPS-encrypted. Plaintext files (`*.local.yaml`) are gitignored.
