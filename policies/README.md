# Policy-as-Code

This directory holds policies for Kyverno and Conftest (Open Policy Agent / Rego).
They are consumed by the IaC Security Pipeline (`IaC.yml`) and the App Security Pipeline (`apps.yml`) deploy-scan jobs.

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

1. Write the policy in the appropriate format (Kyverno YAML or Rego).
2. Place it in this directory.
3. Run it locally before pushing:
   - Kyverno: `docker run --rm -v "$PWD:/src" ghcr.io/kyverno/kyverno-cli:v1.13.0 apply /src/policies/ --resource /src/rendered-manifests.yaml`
   - Conftest: `docker run --rm -v "$PWD:/src" openpolicyagent/conftest:v0.56.0 test /src/rendered-manifests.yaml`
