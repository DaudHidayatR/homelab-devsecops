# Future direct-access Tailscale operator policy.
# Prefer ESO indirect sync for this project unless the operator needs direct OpenBao auth.

path "secret/data/tailscale/operator-oauth" {
  capabilities = ["read"]
}

path "secret/metadata/tailscale/operator-oauth" {
  capabilities = ["read", "list"]
}

path "identity/entity/*" {
  capabilities = ["read", "list"]
}
