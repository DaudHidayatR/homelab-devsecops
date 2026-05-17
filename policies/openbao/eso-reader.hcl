# External Secrets Operator reader policy.
# Keep this path-enumerated. Add one explicit path per ExternalSecret consumer.

path "secret/data/messaging/rabbitmq" {
  capabilities = ["read"]
}
path "secret/metadata/messaging/rabbitmq" {
  capabilities = ["read", "list"]
}

path "secret/data/tailscale/operator-oauth" {
  capabilities = ["read"]
}
path "secret/metadata/tailscale/operator-oauth" {
  capabilities = ["read", "list"]
}

path "secret/data/demo/sample-app" {
  capabilities = ["read"]
}
path "secret/metadata/demo/sample-app" {
  capabilities = ["read", "list"]
}

path "secret/data/ci/deploy" {
  capabilities = ["read"]
}
path "secret/metadata/ci/deploy" {
  capabilities = ["read", "list"]
}
