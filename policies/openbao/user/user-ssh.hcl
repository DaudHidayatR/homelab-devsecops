# Human SSH certificate signing policy.
# Per-user roles are named by stable identity.entity.id and are created by
# scripts/openbao/create-user.sh --ssh.

path "ssh-client-signer/sign/{{identity.entity.id}}" {
  capabilities = ["create", "update"]
}
