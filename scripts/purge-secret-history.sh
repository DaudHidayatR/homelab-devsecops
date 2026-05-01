#!/usr/bin/env bash
# Script to purge the exposed RabbitMQ secret from Git history.
# WARNING: This rewrites history. All contributors must re-clone.
# Run this ONCE, then force-push.

set -eo pipefail

SECRET_FILES=(
  "rabbitmq/secret.yaml"
  "rabbitmq/core/secret.yaml"
)

echo "=== Git Secret History Purge ==="
echo ""
echo "This script will remove the following files from Git history:"
for f in "${SECRET_FILES[@]}"; do
  echo "  - $f"
done
echo ""
echo "WARNING: This rewrites Git history. All collaborators must re-clone."
echo "Make sure you have pushed all other important changes before proceeding."
echo ""

read -rp "Are you sure you want to continue? [y/N] " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
  echo "Aborted."
  exit 1
fi

# Check for git-filter-repo
if command -v git-filter-repo &>/dev/null; then
  echo "Using git-filter-repo..."
  for f in "${SECRET_FILES[@]}"; do
    git filter-repo --path "$f" --invert-paths
  done
elif command -v bfg &>/dev/null; then
  echo "Using BFG Repo-Cleaner..."
  # BFG requires the file to exist in the latest commit
  # First, ensure the files are removed from current tree
  for f in "${SECRET_FILES[@]}"; do
    if [ -f "$f" ]; then
      git rm -f "$f"
    fi
  done
  git commit -m "chore: remove secret files before BFG cleanup"
  # Run BFG
  bfg --delete-files "$(IFS='|'; echo "${SECRET_FILES[*]}")"
  git reflog expire --expire=now --all
  git gc --prune=now --aggressive
else
  echo "ERROR: Neither git-filter-repo nor BFG is installed."
  echo ""
  echo "Install one of them:"
  echo "  pip install git-filter-repo"
  echo "    OR"
  echo "  wget https://repo1.maven.org/maven2/com/madgag/bfg/1.14.0/bfg-1.14.0.jar"
  echo ""
  echo "Alternatively, you can manually rewrite history with:"
  echo "  git rebase -i --root"
  echo "  # Edit each commit that introduced the secret"
  exit 1
fi

echo ""
echo "=== History rewritten ==="
echo "Next steps:"
echo "  1. Verify: git log --all --full-history -- rabbitmq/secret.yaml"
echo "     (should return nothing)"
echo "  2. Force-push: git push origin --force --all"
echo "  3. Notify all contributors to re-clone the repository"
echo "  4. Rotate the secret in any deployed systems"
echo ""
echo "IMPORTANT: If this repo is mirrored or forked, clean those too."
