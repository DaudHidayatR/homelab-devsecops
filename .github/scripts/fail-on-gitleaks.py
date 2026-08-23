#!/usr/bin/env python3
"""Fail the CI job when the GitLeaks JSON report contains findings.

Usage: fail-on-gitleaks.py <gitleaks-report.json>
Exit 0 when the report is an empty list (no findings); exit 1 otherwise.
"""
import json
import sys


def main(argv):
    if len(argv) < 2:
        print("ERROR: missing report path")
        return 1
    path = argv[1]
    try:
        with open(path) as f:
            data = json.load(f)
    except Exception as exc:
        print(f"ERROR: cannot read {path}: {exc}")
        return 1
    if isinstance(data, list) and not data:
        print("No GitLeaks findings.")
        return 0
    print("ERROR: GitLeaks detected secrets. See gitleaks-report.json.")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
