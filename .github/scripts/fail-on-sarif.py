#!/usr/bin/env python3
"""Fail a CI job when SARIF reports contain HIGH/CRITICAL (error-level) findings.

Usage: fail-on-sarif.py <report.sarif> [<report.sarif> ...]
Exit 0 when no blocking findings; exit 1 (with a listing) otherwise.
"""
import json
import sys


def blocking_findings(path):
    """Collect blocking (error/high/critical) findings from a SARIF file or
    from a directory containing checkov's SARIF output (results_sarif.json
    or *.sarif)."""
    import os

    if os.path.isdir(path):
        names = os.listdir(path)
        candidates = [os.path.join(path, f) for f in names if f.endswith(".json") or f.endswith(".sarif")]
        if not candidates:
            print(f"ERROR: no SARIF file inside {path}")
            return [(path, "no-sarif", "error")]
        paths = candidates
    else:
        paths = [path]

    findings = []
    for p in paths:
        try:
            with open(p) as f:
                data = json.load(f)
        except Exception as exc:
            print(f"ERROR: cannot read {p}: {exc}")
            findings.append((p, "unreadable", "error"))
            continue

        for run in data.get("runs", []):
            rules = {}
            for rule in run.get("tool", {}).get("driver", {}).get("rules", []):
                rules[rule.get("id")] = rule
            for result in run.get("results", []):
                level = result.get("level", "warning")
                rule = rules.get(result.get("ruleId"))
                if rule:
                    sev = ((rule.get("properties") or {}).get("problem.severity") or "").lower()
                    if sev == "error":
                        level = "error"
                if level in ("error", "high", "critical"):
                    findings.append((path, result.get("ruleId"), level))
    return findings


def main(argv):
    all_findings = []
    for path in argv[1:]:
        all_findings.extend(blocking_findings(path))

    if all_findings:
        for path, rule_id, level in all_findings:
            print(f"BLOCKING: {path} {rule_id} ({level})")
        return 1
    print("No HIGH/CRITICAL findings in SARIF reports.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
