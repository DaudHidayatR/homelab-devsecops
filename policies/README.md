# Policy-as-Code

This directory holds policies for Kyverno, Conftest (Open Policy Agent / Rego), and OpenBao.
Kyverno and Conftest policies are consumed by the IaC Security Pipeline (`IaC.yml`) and the App Security Pipeline (`apps.yml`) deploy-scan jobs.
OpenBao policies are applied by `scripts/openbao-bootstrap.sh` and `scripts/openbao-apply-policies.sh`.

## OpenBao Policies

OpenBao policy source files live in `policies/openbao/*.hcl`:

```text
policies/openbao/
├── admin.hcl
├── eso-reader.hcl
├── ci-deployer.hcl
├── app-demo.hcl
└── tailscale-operator.hcl
```

Apply them to a running cluster with:

```bash
make openbao-policies
```

Or enable the optional GitHub OIDC role while applying:

```bash
GITHUB_REPOSITORY=owner/repo bash scripts/openbao-apply-policies.sh --enable-jwt
```

Best practice for this repository: keep OpenBao policies in these HCL files as the source of truth, apply them through scripts, and use the OpenBao UI only for verification/debugging.

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
