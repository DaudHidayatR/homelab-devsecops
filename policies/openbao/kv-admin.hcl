# KV v2 metadata and lifecycle administration without secret-value reads.

path "secret/metadata/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "secret/delete/*" {
  capabilities = ["update"]
}

path "secret/undelete/*" {
  capabilities = ["update"]
}

path "secret/destroy/*" {
  capabilities = ["update"]
}

path "secret/data/*" {
  capabilities = ["deny"]
}
