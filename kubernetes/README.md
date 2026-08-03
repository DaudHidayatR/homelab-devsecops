# Policy-as-Code

Cluster policy sources now live with their owning homelab cluster:

```text
kubernetes/clusters/homelab/
├── cluster-policies/
│   ├── network/
│   ├── pod-security/
│   └── resource-governance/
└── platform/openbao/configuration/policies/
    ├── apps/
    └── platform/
```

Kyverno and Conftest consume `cluster-policies/` in the IaC workflow. OpenBao policies are applied through `scripts/homelab openbao bootstrap` and `scripts/homelab openbao policies`.

## OpenBao Policies

Policy roles:

- `system-admin`: operational administration without application secret-value reads.
- `audit-metadata-reader`: metadata/config visibility only; explicitly denies `secret/data/*`.
- `secret-kv-admin`: KV v2 metadata and lifecycle administration without secret-value reads.
- `shared-read-public`: safe shared read-only access to `common/public`.
- `user-default`: human user namespace access using `identity.entity.id`.
- `app-default`: app metadata-templated access for explicitly tagged app identities.
- `user-ssh`: human SSH signing access to per-entity SSH roles.
- `ci-deployer`, `app-demo`, and `app-tailscale-operator`: Kubernetes/automation policies.

Apply them with `make openbao-policies`. The explicit registry and principal mapping remain behind `scripts/homelab openbao policies`; an HCL policy alone never creates a principal.

Fresh-cluster order:

```bash
make up
kubectl wait --for=condition=Ready pod/openbao-0 -n openbao --timeout=300s
scripts/homelab openbao bootstrap
make openbao-policies
```

Verification:

```bash
kubectl exec -n openbao openbao-0 -- sh -c 'BAO_ADDR=http://127.0.0.1:8200 bao policy list'
kubectl exec -n openbao openbao-0 -- sh -c 'BAO_ADDR=http://127.0.0.1:8200 bao auth list'
make openbao-status
```

## Cluster Policies

Place Kyverno YAML and Conftest Rego under `kubernetes/clusters/homelab/cluster-policies/`, grouped by enforcement concern. Run `make validate-kustomize` before pushing.
