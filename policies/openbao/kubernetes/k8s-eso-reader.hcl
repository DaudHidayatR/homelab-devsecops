# External Secrets Operator reader policy.
# Keep this path-enumerated. Add one explicit path per ExternalSecret consumer.

path "secret/data/messaging/rabbitmq" {
  capabilities = ["read"]
}
