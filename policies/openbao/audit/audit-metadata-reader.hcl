# Auditor policy: metadata and configuration visibility only.
# Does not grant secret-value reads.

path "secret/metadata/*" {
  capabilities = ["read", "list"]
}

path "sys/mounts" {
  capabilities = ["read"]
}

path "sys/auth" {
  capabilities = ["read"]
}

path "sys/policies/acl" {
  capabilities = ["read", "list"]
}

path "sys/policies/acl/*" {
  capabilities = ["read", "list"]
}

path "identity/entity/id/*" {
  capabilities = ["read"]
}

path "identity/entity/name/*" {
  capabilities = ["read"]
}

path "sys/audit" {
  capabilities = ["read"]
}

path "sys/audit/*" {
  capabilities = ["read"]
}

path "secret/data/*" {
  capabilities = ["deny"]
}
