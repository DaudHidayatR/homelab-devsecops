# GitHub Actions CI/CD deployer policy.
# Intended for auth/jwt/role/ci-deployer using GitHub OIDC.

path "secret/data/ci/deploy" {
  capabilities = ["read"]
}

path "secret/metadata/ci/deploy" {
  capabilities = ["read", "list"]
}

path "sys/seal-status" {
  capabilities = ["read"]
}
