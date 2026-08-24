#!/usr/bin/env python3
"""Assert IaC.yml push+PR path filters react to HCL, Rego, Makefile, and
config.env.example changes while unrelated paths stay excluded. Stdlib only.
Optional argv[1]: path to an alternative workflow file (for RED checks)."""
import fnmatch, pathlib, re, sys

DEFAULT = pathlib.Path(__file__).resolve().parent.parent / ".github/workflows/IaC.yml"
REQUIRED = ["**.hcl", "**.rego", "Makefile", "**/Makefile", "config.env.example"]
MUST_TRIGGER = ["infra/net/main.hcl", "policy/team-a.policies.rego", "Makefile",
                "scripts/nested/Makefile", "config.env.example"]
MUST_NOT_TRIGGER = ["docs/README.md", "assets/logo.svg"]

def patterns_for(text, trigger):
    """Return (patterns, placement_problems) for a trigger block.
    Placement check: every pattern line must be indented deeper than its
    paths: key (guards against list items escaping the mapping)."""
    m = re.search(r"\n(  )%s:\n" % trigger, text)
    if m is None:
        raise ValueError("trigger block not found: %s" % trigger)
    i = m.start()
    j = text.index("\n    paths:", i)
    key_indent = len(text[j+1:]) and len(re.match(r"[ \t]*", text[j+1:]).group(0))
    k_end = text.find("\njobs:", i)
    k = k_end if k_end != -1 else len(text)
    pats, problems = [], []
    for lm in re.finditer(r"( *)[|-] \"([^\"]+)\"", text[j:k]):
        if len(lm.group(1)) <= key_indent:
            problems.append("pattern %r not indented under paths:" % lm.group(2))
        pats.append(lm.group(2))
    return pats, problems

def main():
    wf = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT
    text = wf.read_text()
    failures = []
    for trigger in ("push", "pull_request"):
        pats, placement = patterns_for(text, trigger)
        failures += ["%s: %s" % (trigger, prob) for prob in placement]
        for req in REQUIRED:
            if req not in pats:
                failures.append("%s: missing pattern %s" % (trigger, req))
        for pth in MUST_TRIGGER:
            if not any(fnmatch.fnmatch(pth, pat) for pat in pats):
                failures.append("%s: %s should trigger" % (trigger, pth))
        for pth in MUST_NOT_TRIGGER:
            if any(fnmatch.fnmatch(pth, pat) for pat in pats):
                failures.append("%s: %s must NOT trigger" % (trigger, pth))
    for f in failures:
        print("FAIL:", f)
    return 1 if failures else 0

sys.exit(main())
