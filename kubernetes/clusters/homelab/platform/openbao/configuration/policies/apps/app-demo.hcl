# Direct-access demo application policy.

path "secret/data/demo/sample-app" {
  capabilities = ["read"]
}

path "secret/metadata/demo/sample-app" {
  capabilities = ["read", "list"]
}

path "identity/entity/*" {
  capabilities = ["read", "list"]
}
