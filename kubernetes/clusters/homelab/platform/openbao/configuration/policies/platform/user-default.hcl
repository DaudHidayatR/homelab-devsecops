# Default human user policy.
# Uses stable identity.entity.id, not mutable entity names.

path "secret/data/users/{{identity.entity.id}}/*" {
  capabilities = ["create", "read", "update", "delete"]
}

path "secret/metadata/users/{{identity.entity.id}}/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "secret/data/common/public/*" {
  capabilities = ["read"]
}

path "secret/metadata/common/public/*" {
  capabilities = ["read", "list"]
}
