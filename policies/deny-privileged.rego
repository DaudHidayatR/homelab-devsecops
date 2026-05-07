# Deny privileged containers (Kubernetes manifests)
# This policy mirrors the Kyverno disallow-privileged rule in Rego
# for Conftest consumption.

package main

deny[msg] {
  input.kind == "Pod"
  container := input.spec.containers[_]
  container.securityContext.privileged == true
  msg := sprintf("Container %s in Pod %s must not be privileged", [container.name, input.metadata.name])
}

deny[msg] {
  input.kind == "Pod"
  container := input.spec.initContainers[_]
  container.securityContext.privileged == true
  msg := sprintf("Init container %s in Pod %s must not be privileged", [container.name, input.metadata.name])
}
