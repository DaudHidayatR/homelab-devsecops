# Direct-access Tailscale operator policy.

path "secret/data/tailscale/operator-oauth" {
  capabilities = ["read"]
}

path "secret/metadata/tailscale/operator-oauth" {
  capabilities = ["read", "list"]
}

path "identity/entity/*" {
  capabilities = ["read", "list"]
}
