# Safe shared read-only policy for authenticated users.
# Scope is intentionally limited to common/public only.

path "secret/data/common/public/*" {
  capabilities = ["read"]
}

path "secret/metadata/common/public/*" {
  capabilities = ["read", "list"]
}
