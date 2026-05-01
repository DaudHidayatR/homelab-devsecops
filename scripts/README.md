# Scripts

This directory contains standalone automation scripts. **They are intentionally NOT committed to this repository.**

These are universal tools designed to be **copied into any Git repository** where you need to purge secrets from history. Do not commit them here — copy them to the target repository and run them there.

| Script | Purpose | Interactive |
|--------|---------|-------------|
| `auto-purge-secret.sh` | Universal Git secret history purge with **Gitleaks** discovery | Yes |
| `purge-secret-history.sh` | Basic Git history purge (legacy) | Minimal |
| `purge-config.example.toml` | Example config for `auto-purge-secret.sh` | — |

---

## How to Use in Another Repository

```bash
# 1. Copy the script into the repository that has the secret
cp /path/to/project-ssdlc-devsecops-boilerplate/infra/kind/scripts/auto-purge-secret.sh /path/to/target-repo/auto-purge-secret.sh
chmod +x /path/to/target-repo/auto-purge-secret.sh

# 2. Run it inside the target repository
cd /path/to/target-repo
./auto-purge-secret.sh --auto
```

---

## Quick Start: `auto-purge-secret.sh`

A **universal**, repo-agnostic script that removes secrets from Git history. It works in **any Git repository** — not just this project.

### Requirements

| Requirement | Version | Install Command |
|-------------|---------|-----------------|
| Bash | >= 4.0 | usually pre-installed |
| Git | >= 2.24 | `apt install git` / `brew install git` |
| `git-filter-repo` | latest | `pip install git-filter-repo` |
| Gitleaks (optional) | >= 8.0 | `brew install gitleaks` or use Docker |
| GPG or SSH key (optional) | any | only needed if you want to re-sign commits |

### Install Dependencies

```bash
# macOS
brew install git gitleaks
pip install git-filter-repo

# Ubuntu / Debian
sudo apt update && sudo apt install git
pip install git-filter-repo
# Gitleaks: download from https://github.com/gitleaks/gitleaks/releases

# Or use Docker for Gitleaks (no local install needed)
docker pull zricethezav/gitleaks:latest
```

### Usage

#### 1. Auto-detect secrets and purge

```bash
chmod +x scripts/auto-purge-secret.sh
./scripts/auto-purge-secret.sh --auto
```

The script will:
1. Run Gitleaks to find leaked secrets.
2. Ask you to confirm which files to purge.
3. Create a backup clone.
4. Rewrite Git history with `git-filter-repo`.
5. Detect signed commits and offer re-signing.
6. Validate with Gitleaks again.
7. Prompt before force-pushing.

#### 2. Purge specific files

```bash
./scripts/auto-purge-secret.sh \
  --target-file "config/credentials.json" \
  --target-file ".env.production"
```

#### 3. Use a config file

Copy and edit the example config:

```bash
cp scripts/purge-config.example.toml my-config.toml
# edit my-config.toml
./scripts/auto-purge-secret.sh --config my-config.toml
```

#### 4. Non-interactive mode (CI / automation)

```bash
./scripts/auto-purge-secret.sh \
  --auto \
  --yes \
  --force-push \
  --backup-dir /mnt/backups/git-purge
```

> **Warning:** `--yes` skips all confirmation prompts. Use only in trusted automation.

#### 5. Preview without changing anything

```bash
./scripts/auto-purge-secret.sh --auto --dry-run
```
```

### Non-Interactive CI/CD Mode

```bash
./scripts/auto-purge-secret.sh --auto --yes --force-push --no-backup
```

---

## Full Options Reference

```
-f, --target-file <path>   Target a specific file to purge (can repeat)
-p, --target-pattern <rx>  Target files matching a regex pattern
-a, --auto                 Auto-detect secrets using Gitleaks and purge them
-c, --config <path>        Use a config file for settings
-b, --backup-dir <path>    Custom backup directory (default: /tmp/<repo>-backup-<timestamp>)
-n, --no-backup            Skip backup creation
-y, --yes                  Auto-confirm all prompts (use with caution)
    --dry-run              Preview changes without rewriting history
    --list-history         List secret files in history without purging
-v, --verbose              Verbose output
-h, --help                 Show help
```

---

## What the Script Does (Step by Step)

1. **Pre-flight checks** — Verifies `git-filter-repo`, Git repo status, uncommitted changes.
2. **Secret discovery** — Scans for files matching patterns or uses user-specified targets.
3. **Backup** — Creates a mirror clone to `/tmp/<repo>-backup-<timestamp>`.
4. **Signature detection** — Counts GPG/SSH/SMIME signed commits in history.
5. **Interactive prompt** — Asks how to handle signatures if found (re-sign, accept unsigned, or cancel).
6. **History rewrite** — Runs `git filter-repo` to remove secret files.
7. **Verification** — Confirms secrets are gone from history.
8. **Re-sign (optional)** — Re-signs all rewritten commits if chosen (with automatic stash/unstash).
9. **Gitleaks scan** — Re-runs Gitleaks to confirm zero leaks.
10. **Safe push** — Offers force-push only after everything is validated.

---

## Commit Signatures

If your repository uses signed commits, the script will ask:

| Option | Result |
|--------|--------|
| **Re-sign all** | All rewritten commits get new signatures. Requires a GPG or SSH key. |
| **Accept unsigned history** | Historical commits lose "Verified" badge; future commits are signed normally. |
| **Cancel** | No changes made. |

> **Note:** Re-signing stashes any uncommitted changes automatically and restores them afterward.

---

## Legacy Script: `purge-secret-history.sh`

A simpler, non-interactive script for basic history purge:

```bash
chmod +x scripts/purge-secret-history.sh
./scripts/purge-secret-history.sh
```

This script:
- Auto-detects `git-filter-repo` or BFG.
- Purges hardcoded secret files.
- Does **not** handle commit signatures automatically.
- Does **not** validate with Gitleaks afterward.

Use it only if you want full manual control or are working on a repo without signed commits.

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| `git-filter-repo: command not found` | Run `pip install git-filter-repo` |
| `Not a git repository` | Run the script from inside a Git repo |
| `Uncommitted changes` | Commit or stash your work first, or the script will warn you |
| `Gitleaks not found` | Install Gitleaks or let the script use Docker fallback |
| Force-push rejected | You may lack permissions. Ask a repo admin, or use `--no-push` and push manually |
| Re-signing fails | Ensure `user.signingkey` is set in Git config and your key is unlocked |

---

## Safety Checklist

Before running on a production repository:

- [ ] Notify all collaborators that history will be rewritten.
- [ ] Ensure you have force-push permissions on the remote.
- [ ] Verify the backup clone was created successfully.
- [ ] Test on a fork or mirror first if possible.
- [ ] Have a rollback plan (restore from the backup clone).
