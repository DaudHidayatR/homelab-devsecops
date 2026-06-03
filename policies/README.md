# Policy-as-Code

This directory holds policies for Kyverno, Conftest (Open Policy Agent / Rego), and OpenBao.
Kyverno and Conftest policies are consumed by the IaC Security Pipeline (`IaC.yml`) and the App Security Pipeline (`apps.yml`) deploy-scan jobs.
OpenBao policies are applied by `scripts/openbao/bootstrap.sh` and `scripts/openbao/apply-policies.sh`.

## OpenBao Policies

OpenBao policy source files live in `policies/openbao/*.hcl`:

```text
policies/openbao/
├── admin.hcl
├── app-demo.hcl
├── auditor.hcl
├── ci-deployer.hcl
├── default-app.hcl
├── default-read.hcl
├── default-user.hcl
├── eso-reader.hcl
├── kv-admin.hcl
├── ssh-user.hcl
└── tailscale-operator.hcl
```

Policy roles:

- `admin.hcl`: operational administration without application secret-value reads.
- `auditor.hcl`: metadata/config visibility only; explicitly denies `secret/data/*`.
- `kv-admin.hcl`: KV v2 metadata and lifecycle administration without secret-value reads.
- `default-read.hcl`: safe shared read-only access to `common/public`.
- `default-user.hcl`: human user namespace access using `identity.entity.id`.
- `default-app.hcl`: app metadata-templated access for explicitly tagged app identities.
- `ssh-user.hcl`: human SSH signing access to per-entity SSH roles.
- `eso-reader.hcl`, `ci-deployer.hcl`, `app-demo.hcl`, `tailscale-operator.hcl`: existing Kubernetes/automation policies.

Apply them to a running cluster with:

```bash
make openbao-policies
```

Or enable the optional GitHub OIDC role while applying:

```bash
GITHUB_REPOSITORY=owner/repo bash scripts/openbao/apply-policies.sh --enable-jwt
```

Best practice for this repository: keep OpenBao policies in these HCL files as the source of truth, apply them through scripts, and use the OpenBao UI only for verification/debugging.

### OpenBao policy-to-principal mapping

OpenBao HCL files define capabilities only. They do **not** automatically create users, AppRoles, Kubernetes auth roles, identity entities, or aliases.

Principal mapping is intentionally explicit:

| Mapping type | Where it is managed | Why |
|---|---|---|
| Human userpass users | `scripts/openbao/create-user.sh` | User creation needs a password, identity alias, metadata, and optional SSH role |
| Machine/CI AppRoles | `scripts/openbao/create-approle.sh` | AppRole creation emits sensitive RoleID / wrapped SecretID material |
| Kubernetes service-account roles | `scripts/openbao/apply-policies.sh` | A policy file alone should not silently grant a Kubernetes principal access |
| ESO reader role | `scripts/openbao/bootstrap.sh` and reconciled policy scripts | ESO needs bootstrap-time access after OpenBao is initialized/unsealed |

The mapping table in `scripts/openbao/apply-policies.sh` is deliberately reviewable Bash data. If it is ever moved to YAML/env metadata, preserve the same explicit review model and validate that every mapped policy has a corresponding `policies/openbao/*.hcl` file.

### Operational sequence

For a fresh cluster, apply OpenBao policy behavior in this order:

```bash
make up
kubectl wait --for=condition=Ready pod/openbao-0 -n openbao --timeout=300s
bash scripts/openbao/bootstrap.sh
make openbao-policies
bash scripts/openbao/store-rabbitmq.sh
kubectl apply -k infrastructure/external-secrets/stores
```

Use `make openbao-policies` after editing any `policies/openbao/*.hcl` file or after changing the explicit Kubernetes mapping table.

### Verification

```bash
kubectl exec -n openbao openbao-0 -- sh -c 'BAO_ADDR=http://127.0.0.1:8200 bao policy list'
kubectl exec -n openbao openbao-0 -- sh -c 'BAO_ADDR=http://127.0.0.1:8200 bao auth list'
make openbao-status
```

## Kyverno Policies

Place valid Kyverno `ClusterPolicy` or `Policy` YAML manifests here.
The pipeline runs:

```bash
kyverno apply policies/ --resource rendered-manifests.yaml
```

## Conftest Policies

Place Rego (`.rego`) files and their data (`.json`/`.yaml`) here.
The pipeline runs:

```bash
conftest test rendered-manifests.yaml
```

Conftest loads all `.rego` files from the current directory by default.

## Adding New Policies

1. Write the policy in the appropriate format (Kyverno YAML, Rego, or OpenBao HCL).
2. Place it in the appropriate directory:
   - Kyverno/Rego: `policies/`
   - OpenBao: `policies/openbao/`
3. Run it locally before pushing:
   - OpenBao: `make openbao-policies`
   - Kyverno: `docker run --rm -v "$PWD:/src" ghcr.io/kyverno/kyverno-cli:v1.13.0 apply /src/policies/ --resource /src/rendered-manifests.yaml`
   - Conftest: `docker run --rm -v "$PWD:/src" openpolicyagent/conftest:v0.56.0 test /src/rendered-manifests.yaml`
