# DevSecOps Kind Lab — Immediate Fixes Plan

## Objective
Resolve the remaining structural gaps identified in the project: initialize the LLM knowledge wiki, expose the demo application via a Service, and close the network-policy gap in the Headlamp namespace.

## Implementation Plan

### 1. Bootstrap the Wiki Structure

- [x] Create `wiki/index.md` as the master catalog.
  - List all wiki page categories (sources, concepts, entities, comparisons).
  - Catalog existing project components (kind cluster, Istio, RabbitMQ, OpenBao, Headlamp, demo app, security bases).
  - Reference `AGENT.md` as the schema source.
- [x] Create `wiki/log.md` as an append-only chronological history.
  - Seed with an initial entry documenting the wiki creation event.
- [x] Create `wiki/overview.md` as the high-level synthesis.
  - Summarize the project's purpose: minimal rootless Kubernetes & Istio lab.
  - Outline the security posture (Kustomize patches, default-deny network policies, secret management).
- [x] Create the four wiki subdirectories:
  - `wiki/sources/` (already exists)
  - `wiki/concepts/` (already exists)
  - `wiki/entities/` (missing — will create)
  - `wiki/comparisons/` (missing — will create)

### 2. Add Service for the Sample Application

- [x] Create `apps/demo/sample-app/service.yaml`.
  - Define a `ClusterIP` Service selecting `app: sample-app`.
  - Expose TCP port 80 (targeting the container's port 80).
  - Place it in the `demo` namespace (or let Kustomize inject the namespace).
- [x] Update `apps/demo/kustomization.yaml` to include the new Service resource.

### 3. Close the Headlamp Network-Policy Gap

- [x] Create `headlamp/default-deny-ingress.yaml`.
  - Define a `NetworkPolicy` named `default-deny-ingress`.
  - Use an empty `podSelector: {}` to match all pods in the namespace.
  - Set `policyTypes: [Ingress]` to deny all ingress by default.
- [x] Create `headlamp/networkpolicy.yaml`.
  - Define an allow-ingress policy for Headlamp pods (selector `k8s-app: headlamp`).
  - Allow ingress on TCP port 80 from `kube-system` (for internal health checks/probes).
  - Allow ingress on TCP port 80 from `istio-system` if Headlamp is intended to be mesh-accessible; otherwise restrict to `kube-system` and any management CIDRs as appropriate.
- [x] Update `headlamp/kustomization.yaml` to include both new NetworkPolicy resources.

## Verification Criteria

- [x] `wiki/index.md`, `wiki/log.md`, and `wiki/overview.md` exist and render correctly in markdown.
- [x] The four wiki subdirectories (`sources/`, `concepts/`, `entities/`, `comparisons/`) are present.
- [x] `kustomize build apps/demo/` renders the new Service manifest without errors.
- [x] `kustomize build headlamp/` renders both NetworkPolicy manifests without errors.
- [x] The rendered Headlamp manifests include the default-deny policy followed by an explicit allow policy (standard Kubernetes NetworkPolicy ordering behavior).

## Potential Risks and Mitigations

1. **Headlamp Readiness/Liveness Probes Blocked**
   If the allow-policy is too restrictive, kubelet probes from the node may be dropped. The allow-policy must permit traffic from the `kube-system` namespace (where kubelet-proxy/CNI originates in this lab context) or from the node's CIDR.
   *Mitigation*: Explicitly allow ingress from `kubernetes.io/metadata.name: kube-system` in the Headlamp allow-policy, consistent with the existing `demo` and `rabbitmq` allow-policies.

2. **Service Name Collision**
   If a Service named `sample-app` already exists elsewhere in the repo or in the user's cluster, applying the new manifest could conflict.
   *Mitigation*: Use the name `sample-app` to match the Deployment name, which is a standard convention and no conflicting Service currently exists in the repo.

3. **Wiki Content Drift**
   Without an initial ingestion of source files, the wiki may quickly become stale.
   *Mitigation*: Seed `index.md` with references back to `README.md`, `AGENT.md`, `setup.sh`, and `destroy.sh` so future ingestion workflows have a starting point.

## Alternative Approaches

1. **Headlamp NetworkPolicy — Single Combined Policy**
   Instead of separate `default-deny-ingress.yaml` + `networkpolicy.yaml` files, create one NetworkPolicy that both selects all pods and explicitly allows Headlamp ingress. This reduces file count but diverges from the established pattern in other namespaces (`demo/`, `rabbitmq/`, `openbao/`).

2. **Service Type — NodePort instead of ClusterIP**
   For local testing without port-forwarding, a `NodePort` Service could be used. This is less secure and inconsistent with the project's `kubectl port-forward` access model documented in `README.md`.

3. **Wiki Automation — Skip Manual Seeding**
   Wait for an automated ingestion agent to populate the wiki. This delays knowledge persistence and leaves the wiki empty until an external trigger occurs.
