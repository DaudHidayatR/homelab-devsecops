# Principles in Practice — Refactoring Plan

## Objective

Refactor the repository to actively demonstrate the software design principles defined in `wiki/concepts/software-design-principles.md`. Every change must have a clear principle justification.

---

## Principles Applied

### DRY — Don't Repeat Yourself

**Violation found:** `setup.sh:19-21` repeats the same `kubectl create namespace ... | kubectl apply -f -` pattern three times.

**Fix:** Extract a bash helper function `ensure_namespace()` in `setup.sh` and call it in a loop over the namespace list.

### SRP — Single Responsibility Principle

**Violation found:** `setup.sh:77-103` mixes infrastructure orchestration with end-user access instructions. The "Setup Complete" block tells users how to access Headlamp, RabbitMQ, and OpenBao.

**Fix:** Extract `scripts/show-access-info.sh`. `setup.sh` ends after infrastructure is ready. Access info is displayed by a dedicated script that can be run independently.

### KISS — Keep It Simple, Stupid

**Fix:** The extracted helper and script are trivial (one function, one `cat <<EOF`). No new tools, no frameworks, no YAML boilerplate.

### TDA — Tell, Don't Ask

**Fix:** The Makefile already follows TDA — `make up` tells the system to deploy; `make access-info` tells it to show URLs. Users do not ask "what was the script name again?"

---

## Implementation Tasks

- [ ] **Task 1:** Refactor `setup.sh` namespace creation into `ensure_namespace()` helper function.
- [ ] **Task 2:** Extract `setup.sh:77-103` into `scripts/show-access-info.sh`.
- [ ] **Task 3:** Update `setup.sh` to call `scripts/show-access-info.sh` at the end.
- [ ] **Task 4:** Add `access-info` target to `Makefile`.
- [ ] **Task 5:** Create `wiki/principles-in-practice.md` documenting how each principle maps to repo decisions.
- [ ] **Task 6:** Run `bash -n` syntax checks on all modified scripts.

---

## What We Explicitly Avoid

| Not Doing | Principle Justification |
|-----------|------------------------|
| Creating a `scripts/lib/` directory with sourced helpers | KISS — one helper function inline is simpler than a module system for a single script. |
| Rewriting in Go or Ansible | YAGNI — the wiki explicitly says bash is the right tool for <300-line orchestration. |
| Adding a complex argument parser to `setup.sh` | KISS — no flags needed today. |

---

## Verification Criteria

- `bash -n setup.sh` passes.
- `bash -n scripts/show-access-info.sh` passes.
- `make up` still orchestrates the full setup.
- `make access-info` prints the same output that `setup.sh` previously printed.
