# Default application policy.
# Requires identity metadata key app to be set explicitly on the entity.

path "secret/data/apps/{{identity.entity.metadata.app}}/*" {
  capabilities = ["read"]
}

path "secret/metadata/apps/{{identity.entity.metadata.app}}/*" {
  capabilities = ["read", "list"]
}
