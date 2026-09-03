#!/usr/bin/env python3
"""Guard: the CI Kyverno gate must never regress to a silent no-op.

Model (CI-only validation, decision 2026-09-03): Kyverno ClusterPolicies
under kubernetes/clusters/homelab/cluster-policies/ are validated in CI
against rendered manifests; they are deliberately NOT deployed to the
cluster. This script pins the CI wiring to the policy sources so the two
cannot drift apart:

- at least one ClusterPolicy must exist (a Kyverno gate fed zero policies
  applies zero rules and passes everything silently);
- every ClusterPolicy on disk must be referenced by the IaC workflow
  (a policy added but never wired would never run);
- the workflow must still apply policies against the rendered manifests.
"""

from __future__ import annotations

import pathlib
import re
import sys

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
POLICY_DIR = REPO_ROOT / "kubernetes" / "clusters" / "homelab" / "cluster-policies"
WORKFLOW = REPO_ROOT / ".github" / "workflows" / "IaC.yml"


def fail(message: str) -> None:
    print(f"ERROR: {message}")
    sys.exit(1)


def main() -> None:
    if not WORKFLOW.is_file():
        fail(f"missing workflow: {WORKFLOW.relative_to(REPO_ROOT)}")
    workflow = WORKFLOW.read_text(encoding="utf-8")
    # Join backslash line continuations so multi-line docker run commands
    # can be matched as single logical lines.
    flat = " ".join(re.sub(r"\\\s*\n", " ", workflow).split())

    if not re.search(r'KYVERNO_IMAGE"?\s+apply\b', flat):
        fail(
            ".github/workflows/IaC.yml has no 'kyverno apply' step: "
            "the CI policy gate is gone"
        )
    if "--resource /src/rendered-manifests.yaml" not in workflow:
        fail(
            "the CI kyverno apply step must evaluate "
            "'--resource /src/rendered-manifests.yaml' (rendered manifests), "
            "not raw sources"
        )

    if not POLICY_DIR.is_dir():
        fail(f"missing policy directory: {POLICY_DIR.relative_to(REPO_ROOT)}")

    policies = sorted(POLICY_DIR.rglob("*.yaml"))
    if not policies:
        fail(
            "no ClusterPolicy YAML under "
            f"{POLICY_DIR.relative_to(REPO_ROOT)}: the CI Kyverno gate would "
            "apply 0 rules (silent no-op)"
        )

    for policy in policies:
        rel = policy.relative_to(REPO_ROOT)
        text = policy.read_text(encoding="utf-8")
        if "kind: ClusterPolicy" not in text:
            fail(f"{rel} does not contain a ClusterPolicy document")
        if str(rel) not in workflow:
            fail(
                f"{rel} is not referenced by .github/workflows/IaC.yml: "
                "wire it into the 'Kyverno policy check' step or remove it"
            )

    print(
        f"ok: {len(policies)} ClusterPolicy(s) wired into the CI Kyverno gate "
        "(CI-only validation; policies are never deployed)"
    )


if __name__ == "__main__":
    main()
