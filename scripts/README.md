# infra/kind/scripts

Operational helper scripts for the local kind DevSecOps lab.

These scripts are committed project tooling. They support OpenBao bootstrap and access management, External Secrets handoff, Tailscale Serve configuration, access discovery, security scanning, and emergency Git secret cleanup.

## Recommended fresh-cluster flow

Run commands from `infra/kind` unless noted otherwise.

```bash
# 1. Create/update the local kind cluster and deploy infrastructure/apps.
make up

# 2. Wait for OpenBao to be ready.
kubectl wait --for=condition=Ready pod/openbao-0 -n openbao --timeout=300s

# 3. Initialize/unseal OpenBao and configure baseline engines/auth/policies.
bash scripts/openbao/bootstrap.sh

# 4. Reconcile OpenBao policies and identity mappings when needed.
make openbao-policies

# 5. Store application secrets in OpenBao.
bash scripts/openbao/store-rabbitmq.sh

# 6. Apply ESO resources that depend on bootstrapped OpenBao.
kubectl apply -k infrastructure/external-secrets/stores

# 7. Verify generated Kubernetes secrets and access endpoints.
kubectl get clustersecretstore openbao
kubectl get externalsecret rabbitmq-credentials -n messaging
kubectl get secret rabbitmq-credentials -n messaging
make access-info
```

## OpenBao lifecycle

`make up` deploys OpenBao, but it intentionally does **not** initialize or unseal OpenBao. Root tokens, unseal keys, AppRole wrapping tokens, and user passwords must stay outside Git.

Lifecycle:

1. `scripts/cluster/setup.sh` / `make up` deploys OpenBao through Flux using the lab's HTTP listener model.
2. `scripts/openbao/bootstrap.sh` initializes OpenBao if needed, unseals it, enables required engines/auth methods, then delegates policy reconciliation.
3. `scripts/openbao/apply-policies.sh` is the single policy reconciliation entrypoint for registered files and explicit Kubernetes auth/entity mappings.
4. `scripts/openbao/create-user.sh` creates human `userpass` users and optional per-user SSH signing roles.
5. `scripts/openbao/create-approle.sh` creates machine/CI AppRoles with response-wrapped single-use SecretIDs.
6. `scripts/openbao/store-rabbitmq.sh` writes RabbitMQ credentials into OpenBao KV v2.
7. `kubectl apply -k infrastructure/external-secrets/stores` creates the `ClusterSecretStore` and `ExternalSecret` resources that sync from OpenBao into Kubernetes Secrets.

### Default user and AppRole behavior

No standing OpenBao human user or machine AppRole is required by default.

Recommended explicit creation:

```bash
OPENBAO_USER=alice OPENBAO_PASSWORD='change-me' OPENBAO_POLICY=user-default OPENBAO_SSH=true make openbao-create-user
OPENBAO_USER=sagash OPENBAO_PASSWORD='change-me' OPENBAO_POLICY=user-default,system-admin,user-ssh OPENBAO_SSH=true make openbao-create-user
make openbao-create-approle ROLE=ci-robot POLICY=ci-deployer
```

Optional bootstrap defaults are opt-in only:

```bash
OPENBAO_CREATE_DEFAULT_ADMIN=true bash scripts/openbao/bootstrap.sh
OPENBAO_CREATE_DEFAULT_APPROLE=true bash scripts/openbao/bootstrap.sh
```

Use these flags only when you intentionally want bootstrap to create default credentials. Prefer named users/AppRoles for normal operation.

### Sensitive local outputs

The OpenBao scripts may write sensitive material below:

```text
.runtime-backups/openbao/
```

Examples include root token backup, unseal key backup, AppRole RoleID files, and wrapped SecretID tokens. Keep this directory out of Git, preserve restrictive permissions, and back it up securely if the lab state matters.

## Script catalog

| Script | Phase | Purpose | Safe to rerun | Requires OpenBao token/root backup | Creates or stores secrets | Verification |
|---|---|---|---:|---:|---:|---|
| `scripts/openbao/bootstrap.sh` | First-run OpenBao | Initialize/unseal OpenBao; enable KV v2, SSH signer, Kubernetes auth, userpass, AppRole; apply baseline policies; create ESO role | Mostly | Uses generated/restored root material | Yes | `make openbao-status` |
| `scripts/openbao/apply-policies.sh` | OpenBao reconciliation | Apply registered policy files under `policies/openbao/` and explicit Kubernetes auth/entity/alias mappings | Yes | Yes, or `OPENBAO_TOKEN` | No | `kubectl exec -n openbao openbao-0 -- sh -c 'BAO_ADDR=http://127.0.0.1:8200 bao policy list'` |
| `scripts/openbao/create-user.sh` | Human access | Create/update userpass user, identity entity/alias, profile metadata, optional SSH role | Yes | Yes, or admin token | Yes | `make openbao-status` then login with userpass |
| `scripts/openbao/create-approle.sh` | Machine/CI access | Create/update AppRole with short-lived token and response-wrapped single-use SecretID | Yes | Yes, or admin token | Yes | `ls .runtime-backups/openbao/approles/` |
| `scripts/openbao/store-rabbitmq.sh` | App secret seed | Store RabbitMQ credentials at `secret/data/messaging/rabbitmq` | Yes | Yes, or admin token | Yes | `kubectl get secret rabbitmq-credentials -n messaging` after ESO sync |
| `scripts/openbao/status.sh` | Diagnostics | Show pod, seal, auth, policy, and backup status | Yes | Optional | No | Script output |
| `scripts/tailscale/configure-serve.sh` | Tailscale access | Configure Tailscale Serve on Kubernetes proxy pods | Yes | No | No | `./scripts/tailscale/check-access.sh` |
| `scripts/access/show-info.sh` | Access info | Print local and tailnet URLs plus post-setup reminders | Yes | No | No | Script output |
| `scripts/security/scan.sh` | Security validation | Run local scanner suite through containers and validate generated reports | Yes | No | No | `make validate` |
| `scripts/git/auto-purge-secret.sh` | Emergency Git cleanup | Rewrite Git history to remove leaked secrets, with Gitleaks-assisted discovery | Destructive; use with care | No | No | Gitleaks clean scan |

## OpenBao script details

### `scripts/openbao/bootstrap.sh`

Use after `make up` has deployed the OpenBao pod.

```bash
bash scripts/openbao/bootstrap.sh
```

Main effects:

- waits for `openbao-0` in namespace `openbao`
- initializes OpenBao when uninitialized
- stores local root/unseal material under `.runtime-backups/openbao/`
- unseals OpenBao
- enables KV v2 at `secret/`
- enables SSH signer at `ssh-client-signer/`
- enables Kubernetes auth, userpass auth, and AppRole auth
- applies baseline OpenBao policies
- creates Kubernetes auth role(s) needed by ESO
- optionally creates default admin/AppRole only when explicit env flags are set

Useful environment flags:

| Variable | Default | Purpose |
|---|---|---|
| `OPENBAO_CREATE_DEFAULT_ADMIN` | unset/false | Create an opt-in default admin user during bootstrap |
| `OPENBAO_CREATE_DEFAULT_APPROLE` | unset/false | Create an opt-in default `ci-robot` AppRole during bootstrap |

### `scripts/openbao/apply-policies.sh`

Use for repeatable policy-as-code reconciliation.

```bash
make openbao-policies
# or
OPENBAO_TOKEN=<token> bash scripts/openbao/apply-policies.sh
```

Important behavior:

- Registered HCL files under `policies/openbao/` are the policy source of truth.
- Kubernetes auth roles and identity aliases are driven by an explicit mapping table inside the script.
- A policy file alone does not automatically create a Kubernetes principal.
- Re-running is expected after policy changes.

### `scripts/openbao/create-user.sh`

Use for human access.

```bash
OPENBAO_USER=alice OPENBAO_PASSWORD='change-me' OPENBAO_POLICY=user-default OPENBAO_SSH=true make openbao-create-user
OPENBAO_USER=sagash OPENBAO_PASSWORD='change-me' OPENBAO_POLICY=user-default,system-admin,user-ssh OPENBAO_SSH=true make openbao-create-user
# or
OPENBAO_USER=alice OPENBAO_PASSWORD='change-me' OPENBAO_POLICY=user-default OPENBAO_SSH=true bash scripts/openbao/create-user.sh
OPENBAO_USER=sagash OPENBAO_PASSWORD='change-me' OPENBAO_POLICY=user-default,system-admin,user-ssh OPENBAO_SSH=true bash scripts/openbao/create-user.sh
```

Behavior:

- creates/updates a userpass user
- attaches the requested policy or comma-separated policy list, defaulting to `user-default` through the Makefile
- creates/updates an identity entity and userpass alias
- stores non-sensitive profile metadata in KV
- optionally creates a per-user SSH signing role when `SSH=true` / `--ssh` is used

### `scripts/openbao/create-approle.sh`

Use for machine, CI, or automation access.

```bash
make openbao-create-approle ROLE=ci-robot POLICY=ci-deployer
# or
bash scripts/openbao/create-approle.sh ci-robot ci-deployer
```

Behavior:

- requires the target policy to already exist
- creates/updates the AppRole
- prints/saves RoleID metadata
- creates a response-wrapped, single-use SecretID
- stores local output under `.runtime-backups/openbao/approles/`

Treat wrapped SecretID tokens as secrets. They are time-bound and should be delivered only to the intended automation system.

### `scripts/openbao/store-rabbitmq.sh`

Use after OpenBao is initialized/unsealed and before applying the ESO store resources.

```bash
bash scripts/openbao/store-rabbitmq.sh
kubectl apply -k infrastructure/external-secrets/stores
```

Ownership model:

- OpenBao owns the source secret at `secret/data/messaging/rabbitmq`.
- ESO owns the sync definition through `ClusterSecretStore` and `ExternalSecret`.
- Kubernetes owns the generated `messaging/rabbitmq-credentials` Secret as an output.

Do not manually edit generated Kubernetes Secrets for long-term changes; update OpenBao and let ESO reconcile.

## ESO troubleshooting

| Symptom | Check |
|---|---|
| `ClusterSecretStore/openbao` is not ready | Confirm OpenBao is unsealed: `make openbao-status` |
| ESO auth fails | Re-run `bash scripts/openbao/bootstrap.sh` and `make openbao-policies` |
| RabbitMQ Secret missing | Confirm `scripts/openbao/store-rabbitmq.sh` completed, then re-apply `infrastructure/external-secrets/stores` |
| Policy denied errors | Confirm the ESO Kubernetes auth role points at the expected service account/namespace |

## Tailscale access helpers

`scripts/cluster/setup.sh` is the primary path for Tailscale when credentials are present in `config.env`:

```text
TAILSCALE_CLIENT_ID
TAILSCALE_CLIENT_SECRET
```

When enabled, setup creates the OAuth Secret, installs the operator, annotates the OpenBao service, and configures Tailscale Serve through the single selector at `scripts/tailscale/configure-serve.sh`.

Manual/recovery helpers live mostly in `scripts/tailscale/`:

```bash
BACKUP_DIR=.runtime-backups/tailscale/<timestamp> make recover
./scripts/tailscale/reset-proxies.sh
./scripts/tailscale/sign-proxies.sh --sudo
./scripts/tailscale/check-access.sh
./scripts/tailscale/configure-serve.sh
```

Use `make recover` for a full cluster rebuild so validated identity is restored before the operator starts.

## Security scanning

Run all scanner checks:

```bash
make scan
```

Run individual scanner groups through Make targets when needed:

```bash
make sast
make secrets
make sca
make sbom
make iac
make validate
```

Generated reports are ignored by Git.

## Emergency Git secret cleanup scripts

`auto-purge-secret.sh` is the reviewed emergency tool for removing leaked secrets from Git history. It rewrites history and can disrupt collaborators.

Use only after:

- rotating the leaked secret first
- notifying collaborators
- creating a backup/mirror clone
- testing on a fork or disposable clone
- confirming you have permission to force-push

Use `auto-purge-secret.sh` with a reviewed `purge-config.toml` configuration.
