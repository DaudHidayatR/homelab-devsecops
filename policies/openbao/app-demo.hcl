# Future direct-access demo application policy.
# Not used while applications consume secrets indirectly through External Secrets Operator.

path "secret/data/demo/sample-app" {
  capabilities = ["read"]
}

path "secret/metadata/demo/sample-app" {
  capabilities = ["read", "list"]
}

path "identity/entity/*" {
  capabilities = ["read", "list"]
}
