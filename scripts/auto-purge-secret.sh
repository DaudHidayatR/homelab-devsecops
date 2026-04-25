#!/usr/bin/env bash
###############################################################################
# Automated Git History Secret Purge Script
#
# PURPOSE:
#   Removes secret files from Git history, then handles commit signature
#   re-signing based on user preference.
#
# REQUIREMENTS:
#   - git-filter-repo (pip install git-filter-repo)
#   - git >= 2.24
#   - GPG or SSH key configured (only if re-signing)
#
# SAFETY:
#   - Creates a full mirror backup before any destructive operation.
#   - Interactive prompts at every decision point.
#   - Validates results before suggesting force-push.
#
# USAGE:
#   ./scripts/auto-purge-secret.sh [--auto-resign] [--backup-dir /path]
###############################################################################

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BACKUP_DIR="${BACKUP_DIR:-/tmp/repo-backup-$(date +%Y%m%d-%H%M%S)}"
SECRET_FILES=(
  "rabbitmq/secret.yaml"
  "rabbitmq/core/secret.yaml"
)
GITLEAKS_COMMIT="aefc402734b520f1b25fba9bef1d72eddc6ad77e"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

prompt_yes_no() {
  local prompt="$1"
  local response
  while true; do
    read -rp "$prompt [y/N] " response
    case "$response" in
      [Yy]* ) return 0 ;;
      [Nn]* | "" ) return 1 ;;
      * ) echo "Please answer y or n." ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Pre-flight Checks
# ---------------------------------------------------------------------------
check_prerequisites() {
  log_info "Checking prerequisites..."

  if ! command -v git &>/dev/null; then
    log_error "git is not installed."
    exit 1
  fi

  if ! command -v git-filter-repo &>/dev/null; then
    log_error "git-filter-repo is not installed."
    log_info "Install it with: pip install git-filter-repo"
    exit 1
  fi

  # Check if we are inside a git repo
  if ! git rev-parse --git-dir &>/dev/null; then
    log_error "Not inside a Git repository."
    exit 1
  fi

  # Check for uncommitted changes
  if ! git diff-index --quiet HEAD -- 2>/dev/null; then
    log_warn "You have uncommitted changes."
    if ! prompt_yes_no "Continue anyway? (changes will be lost)"; then
      log_info "Aborted. Commit or stash your changes first."
      exit 0
    fi
  fi

  log_ok "Prerequisites satisfied."
}

# ---------------------------------------------------------------------------
# Backup
# ---------------------------------------------------------------------------
create_backup() {
  log_info "Creating mirror backup to: $BACKUP_DIR"
  mkdir -p "$BACKUP_DIR"
  git clone --mirror "$REPO_ROOT" "$BACKUP_DIR"
  log_ok "Backup created at $BACKUP_DIR"
}

# ---------------------------------------------------------------------------
# Detect Signed Commits
# ---------------------------------------------------------------------------
detect_signed_commits() {
  log_info "Checking for signed commits in history..."

  local signed_count
  signed_count=$(git log --format='%G?' --all | grep -c '^G\|^S' || true)

  if [[ "$signed_count" -gt 0 ]]; then
    log_warn "Detected $signed_count signed commit(s) in history."
    log_warn "Rewriting history will INVALIDATE all signatures."
    return 0
  else
    log_ok "No signed commits detected."
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Rewrite History
# ---------------------------------------------------------------------------
rewrite_history() {
  log_info "Rewriting history to remove secret files..."

  for f in "${SECRET_FILES[@]}"; do
    if git log --all --full-history -- "$f" --quiet; then
      log_info "Removing $f from history..."
      git filter-repo --path "$f" --invert-paths --force
    else
      log_info "$f not found in history. Skipping."
    fi
  done

  log_ok "History rewritten."
}

# ---------------------------------------------------------------------------
# Verify Secret Removal
# ---------------------------------------------------------------------------
verify_removal() {
  log_info "Verifying secret removal from history..."

  local found=0
  for f in "${SECRET_FILES[@]}"; do
    # Check if any commits still reference this file
    local commits
    commits=$(git log --all --full-history -- "$f" --oneline 2>/dev/null || true)
    if [ -n "$commits" ]; then
      log_error "FAILED: $f still exists in history!"
      found=1
    fi
  done

  if [[ "$found" -eq 0 ]]; then
    log_ok "Verified: secret files removed from history."
  else
    log_error "Verification failed. Aborting."
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Re-sign Commits
# ---------------------------------------------------------------------------
resign_commits() {
  log_info "Re-signing all commits in rewritten history..."

  local sign_key=""
  local git_version
  git_version=$(git --version | awk '{print $3}')

  # Check for GPG key
  if command -v gpg &>/dev/null && gpg --list-secret-keys --keyid-format=long | grep -q sec; then
    sign_key=$(gpg --list-secret-keys --keyid-format=long | grep sec | head -1 | awk '{print $2}' | cut -d'/' -f2)
    log_info "Detected GPG key: $sign_key"
  fi

  # Check for SSH key
  if [[ -z "$sign_key" ]] && [[ -f "$HOME/.ssh/id_ed25519.pub" || -f "$HOME/.ssh/id_rsa.pub" ]]; then
    log_info "SSH signing key detected."
    sign_key="ssh"
  fi

  if [[ -z "$sign_key" ]]; then
    log_warn "No GPG or SSH signing key detected."
    log_info "Configure one with:"
    log_info "  git config --global user.signingkey <KEY_ID>"
    log_info "  git config --global commit.gpgsign true"
    return 1
  fi

  log_info "This will re-sign ALL commits on the current branch. This may take a while."
  if ! prompt_yes_no "Proceed with re-signing?"; then
    log_info "Skipping re-sign. Commits will remain unsigned."
    return 1
  fi

  # Rebase from root, signing each commit
  if [[ "$sign_key" == "ssh" ]]; then
    GIT_COMMITTER_DATE="$(date)" git rebase --root --exec 'git commit --amend --no-edit -S'
  else
    GIT_COMMITTER_DATE="$(date)" git rebase --root --exec "git commit --amend --no-edit -S$sign_key"
  fi

  log_ok "All commits re-signed."
}

# ---------------------------------------------------------------------------
# Force Push
# ---------------------------------------------------------------------------
force_push() {
  log_warn "Ready to force-push rewritten history to the remote."
  log_warn "This will overwrite remote history. All collaborators MUST re-clone."

  if ! prompt_yes_no "Force-push to origin?"; then
    log_info "Skipping push. You can push manually later with:"
    log_info "  git push origin --force --all"
    return
  fi

  local remote="origin"
  if git remote | grep -q '^origin$'; then
    remote="origin"
  else
    remote=$(git remote | head -1)
    log_warn "No 'origin' remote found. Using '$remote'."
  fi

  git push "$remote" --force --all
  git push "$remote" --force --tags 2>/dev/null || true

  log_ok "Force-push complete."
}

# ---------------------------------------------------------------------------
# Gitleaks Re-scan
# ---------------------------------------------------------------------------
rescan_gitleaks() {
  log_info "Running Gitleaks validation scan..."

  if command -v gitleaks &>/dev/null; then
    gitleaks detect --source "$REPO_ROOT" --report-format json --report-path "$REPO_ROOT/gitleaks-report.json" -v
  elif command -v docker &>/dev/null; then
    docker run --rm -v "$REPO_ROOT:/path" zricethezav/gitleaks:latest detect --source /path --report-format json --report-path /path/gitleaks-report.json -v
  else
    log_warn "Neither gitleaks nor docker found. Skipping validation scan."
    return
  fi

  local leak_count
  leak_count=$(jq 'length' "$REPO_ROOT/gitleaks-report.json")

  if [[ "$leak_count" -eq 0 ]]; then
    log_ok "Gitleaks scan clean: 0 leaks found."
  else
    log_warn "Gitleaks still reports $leak_count leak(s). Review the report."
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  echo ""
  echo "============================================================"
  echo "  Automated Git Secret History Purge"
  echo "============================================================"
  echo ""
  log_warn "This script will REWRITE Git history. All commit hashes will change."
  log_warn "Collaborators MUST re-clone after this operation."
  echo ""

  if ! prompt_yes_no "Do you want to continue?"; then
    log_info "Aborted by user."
    exit 0
  fi

  check_prerequisites
  create_backup

  local has_signed=false
  if detect_signed_commits; then
    has_signed=true
  fi

  # Ask about signature strategy
  if [[ "$has_signed" == true ]]; then
    echo ""
    log_info "Your repository contains signed commits."
    echo ""
    echo "Options:"
    echo "  1) Re-sign all rewritten commits (slow, best for small repos)"
    echo "  2) Accept unsigned history, sign future commits (recommended)"
    echo "  3) Cancel"
    echo ""

    local choice
    read -rp "Choose an option [1-3]: " choice

    case "$choice" in
      1)
        rewrite_history
        verify_removal
        resign_commits || log_warn "Re-signing skipped or failed."
        ;;
      2)
        rewrite_history
        verify_removal
        log_info "Historical commits will remain unsigned. Future commits should be signed."
        ;;
      3)
        log_info "Aborted."
        exit 0
        ;;
      *)
        log_error "Invalid choice. Aborting."
        exit 1
        ;;
    esac
  else
    rewrite_history
    verify_removal
  fi

  # Final validation
  echo ""
  log_info "Final verification..."
  verify_removal
  rescan_gitleaks

  # Offer to push
  echo ""
  force_push

  # Summary
  echo ""
  echo "============================================================"
  log_ok "Secret purge complete!"
  echo "============================================================"
  echo ""
  echo "Summary:"
  echo "  - Backup:        $BACKUP_DIR"
  echo "  - Secret files:  Removed from history"
  echo "  - Gitleaks scan: Check gitleaks-report.json"
  echo ""
  echo "Next steps:"
  echo "  1. Verify the repository looks correct: git log --oneline"
  echo "  2. If you did not force-push, run: git push origin --force --all"
  echo "  3. Notify all collaborators to re-clone the repository"
  echo "  4. Rotate the secret in any deployed systems"
  echo "  5. If signatures were invalidated, enable 'Require signed commits'"
  echo "     in branch protection rules going forward"
  echo ""
}

main "$@"
