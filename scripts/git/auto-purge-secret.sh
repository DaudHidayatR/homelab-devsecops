#!/usr/bin/env bash
###############################################################################
# Universal Git Secret History Purge Script
#
# PURPOSE:
#   Removes secrets from Git history for ANY repository.
#   Auto-detects secrets via Gitleaks, supports manual file targeting,
#   handles commit signatures, validates results, and safely force-pushes.
#
# REQUIREMENTS:
#   - git-filter-repo (pip install git-filter-repo)
#   - git >= 2.24
#   - Optional: gitleaks (for auto-detection)
#   - Optional: gpg or ssh key (for re-signing)
#
# USAGE:
#   ./auto-purge-secret.sh [OPTIONS]
#
# OPTIONS:
#   -f, --file <path>       Target a specific file to purge (can repeat)
#   -p, --pattern <regex>   Target files matching a regex pattern
#   -a, --auto              Auto-detect secrets using gitleaks and purge them
#   -c, --config <path>     Use a config file for settings
#   -b, --backup-dir <path> Custom backup directory (default: /tmp/repo-backup-<timestamp>)
#   -n, --no-backup         Skip backup creation
#   -y, --yes               Auto-confirm all prompts (use with caution)
#   -s, --sign              Force re-sign commits after purge
#   --no-sign               Skip re-signing even if a key is detected
#   --no-push               Skip the force-push prompt
#   -v, --verbose           Verbose output
#   -h, --help              Show this help
#
# EXAMPLES:
#   # Auto-detect and purge all secrets found by gitleaks
#   ./auto-purge-secret.sh --auto
#
#   # Purge specific files
#   ./auto-purge-secret.sh -f secrets.txt -f config/credentials.json
#
#   # Purge files matching a pattern
#   ./auto-purge-secret.sh -p '.*secret.*\.yaml'
#
#   # Combine auto-detection with specific files
#   ./auto-purge-secret.sh --auto -f my-extra-file.txt
#
#   # Non-interactive mode with custom backup
#   ./auto-purge-secret.sh --auto -y --backup-dir /mnt/backups/git-purge
#
#   # Use a config file
#   ./auto-purge-secret.sh --config ./purge-config.toml
#
# CONFIG FILE FORMAT (TOML-like):
#   secret_files = ["secrets.txt", "config/passwords.json"]
#   secret_patterns = [".*secret.*", ".*credential.*"]
#   backup_dir = "/custom/backup/path"
#   auto_confirm = false
#   re_sign = true
###############################################################################

set -euo pipefail

# ---------------------------------------------------------------------------
# Default Configuration
# ---------------------------------------------------------------------------
SECRET_FILES=()
SECRET_PATTERNS=()
AUTO_DETECT=false
BACKUP_DIR=""
NO_BACKUP=false
AUTO_CONFIRM=false
FORCE_SIGN=false
NO_SIGN=false
NO_PUSH=false
VERBOSE=false
CONFIG_FILE=""

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
CYAN=$'\033[0;36m'
NC=$'\033[0m'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_verbose() { if [[ "$VERBOSE" == true ]]; then echo -e "${CYAN}[VERB]${NC}  $*"; fi; }

prompt_yes_no() {
  local prompt="$1"
  [[ "$AUTO_CONFIRM" == true ]] && return 0
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

show_help() {
  sed -n '7,59p' "$0"
  exit 0
}

# ---------------------------------------------------------------------------
# Argument Parsing
# ---------------------------------------------------------------------------
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -f|--file)
        SECRET_FILES+=("$2")
        shift 2
        ;;
      -p|--pattern)
        SECRET_PATTERNS+=("$2")
        shift 2
        ;;
      -a|--auto)
        AUTO_DETECT=true
        shift
        ;;
      -c|--config)
        CONFIG_FILE="$2"
        shift 2
        ;;
      -b|--backup-dir)
        BACKUP_DIR="$2"
        shift 2
        ;;
      -n|--no-backup)
        NO_BACKUP=true
        shift
        ;;
      -y|--yes)
        AUTO_CONFIRM=true
        shift
        ;;
      -s|--sign)
        FORCE_SIGN=true
        shift
        ;;
      --no-sign)
        NO_SIGN=true
        shift
        ;;
      --no-push)
        NO_PUSH=true
        shift
        ;;
      -v|--verbose)
        VERBOSE=true
        shift
        ;;
      -h|--help)
        show_help
        ;;
      *)
        log_error "Unknown option: $1"
        show_help
        ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Config File Loading
# ---------------------------------------------------------------------------
load_config() {
  [[ -z "$CONFIG_FILE" ]] && return
  [[ ! -f "$CONFIG_FILE" ]] && { log_error "Config file not found: $CONFIG_FILE"; exit 1; }

  log_info "Loading config from $CONFIG_FILE"

  # Simple TOML-like parsing (sufficient for this script)
  while IFS= read -r line; do
    # Skip comments and empty lines
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "$line" ]] && continue

    # Parse secret_files = ["a", "b"]
    if [[ "$line" =~ ^secret_files[[:space:]]*=[[:space:]]*\[(.*)\] ]]; then
      local items="${BASH_REMATCH[1]}"
      # Extract quoted strings
      while [[ "$items" =~ \"([^\"]+)\" ]]; do
        SECRET_FILES+=("${BASH_REMATCH[1]}")
        items="${items#*\""${BASH_REMATCH[1]}"\"}"
      done
    fi

    # Parse secret_patterns = ["a", "b"]
    if [[ "$line" =~ ^secret_patterns[[:space:]]*=[[:space:]]*\[(.*)\] ]]; then
      local items="${BASH_REMATCH[1]}"
      while [[ "$items" =~ \"([^\"]+)\" ]]; do
        SECRET_PATTERNS+=("${BASH_REMATCH[1]}")
        items="${items#*\""${BASH_REMATCH[1]}"\"}"
      done
    fi

    # Parse backup_dir = "path"
    if [[ "$line" =~ ^backup_dir[[:space:]]*=[[:space:]]*\"([^\"]+)\" ]]; then
      BACKUP_DIR="${BASH_REMATCH[1]}"
    fi

    # Parse auto_confirm = true/false
    if [[ "$line" =~ ^auto_confirm[[:space:]]*=[[:space:]]*(true|false) ]]; then
      AUTO_CONFIRM="${BASH_REMATCH[1]}"
    fi

    # Parse re_sign = true/false
    if [[ "$line" =~ ^re_sign[[:space:]]*=[[:space:]]*(true|false) ]]; then
      if [[ "${BASH_REMATCH[1]}" == "true" ]]; then
        FORCE_SIGN=true
      else
        NO_SIGN=true
      fi
    fi
  done < "$CONFIG_FILE"
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

  if ! git rev-parse --git-dir &>/dev/null; then
    log_error "Not inside a Git repository."
    exit 1
  fi

  log_ok "Prerequisites satisfied."
}

# ---------------------------------------------------------------------------
# Auto-Detect Secrets with Gitleaks
# ---------------------------------------------------------------------------
auto_detect_secrets() {
  log_info "Auto-detecting secrets..."

  local gitleaks_found_files=""

  if command -v gitleaks &>/dev/null || command -v docker &>/dev/null; then
    local report_file
    report_file=$(mktemp)

    if command -v gitleaks &>/dev/null; then
      gitleaks detect --source . --report-format json --report-path "$report_file" 2>/dev/null || true
    else
      docker run --rm -v "$(pwd):/src" zricethezav/gitleaks:latest detect --source /src --report-format json --report-path /src/gitleaks-auto.json 2>/dev/null || true
      cp gitleaks-auto.json "$report_file" 2>/dev/null || true
      rm -f gitleaks-auto.json
    fi

    if [[ -f "$report_file" ]] && [[ -s "$report_file" ]]; then
      gitleaks_found_files=$(jq -r '.[] | .File' "$report_file" 2>/dev/null | sort -u || true)
    fi
    rm -f "$report_file"
  else
    log_warn "Gitleaks not found and Docker unavailable. Cannot auto-detect secrets."
    log_info "Install gitleaks: https://github.com/gitleaks/gitleaks"
    return 1
  fi

  if [[ -n "$gitleaks_found_files" ]]; then
    log_warn "Gitleaks detected secrets in the following files:"
    local file
    while IFS= read -r file; do
      [[ -n "$file" ]] && echo "  - $file"
    done <<< "$gitleaks_found_files"

    if prompt_yes_no "Add these files to the purge list?"; then
      while IFS= read -r file; do
        [[ -n "$file" ]] && SECRET_FILES+=("$file")
      done <<< "$gitleaks_found_files"
      log_ok "Added $(echo "$gitleaks_found_files" | wc -l) file(s) from Gitleaks to purge list."
    else
      log_info "Skipping Gitleaks-detected files."
    fi
  else
    log_info "Gitleaks found no secrets."
  fi
}

# ---------------------------------------------------------------------------
# Resolve Patterns to Files
# ---------------------------------------------------------------------------
resolve_patterns() {
  [[ ${#SECRET_PATTERNS[@]} -eq 0 ]] && return

  log_info "Resolving patterns to files in Git history..."

  local all_git_files
  all_git_files=$(git log --all --name-only --pretty=format: | sort -u)

  local pattern matched
  for pattern in "${SECRET_PATTERNS[@]}"; do
    matched=$(echo "$all_git_files" | grep -E "$pattern" || true)
    if [[ -n "$matched" ]]; then
      local file
      while IFS= read -r file; do
        [[ -n "$file" ]] && SECRET_FILES+=("$file")
      done <<< "$matched"
      log_ok "Pattern '$pattern' matched $(echo "$matched" | wc -l) file(s)."
    else
      log_warn "Pattern '$pattern' matched no files."
    fi
  done
}

# ---------------------------------------------------------------------------
# Deduplicate and Validate Targets
# ---------------------------------------------------------------------------
deduplicate_targets() {
  # Remove duplicates while preserving order
  local unique=()
  local seen=""
  local f
  for f in "${SECRET_FILES[@]}"; do
    if [[ "$seen" != *"|$f|"* ]]; then
      unique+=("$f")
      seen="${seen}|$f|"
    fi
  done
  SECRET_FILES=("${unique[@]}")

  if [[ ${#SECRET_FILES[@]} -eq 0 ]]; then
    log_error "No target files specified. Use --file, --pattern, --auto, or a config file."
    log_info "Run with --help for usage examples."
    exit 1
  fi

  log_info "Target files to purge (${#SECRET_FILES[@]} total):"
  for f in "${SECRET_FILES[@]}"; do
    echo "  - $f"
  done
}

# ---------------------------------------------------------------------------
# Backup
# ---------------------------------------------------------------------------
create_backup() {
  [[ "$NO_BACKUP" == true ]] && { log_info "Backup skipped (--no-backup)."; return; }

  [[ -z "$BACKUP_DIR" ]] && BACKUP_DIR="/tmp/repo-backup-$(date +%Y%m%d-%H%M%S)"

  log_info "Creating mirror backup to: $BACKUP_DIR"
  mkdir -p "$(dirname "$BACKUP_DIR")"
  git clone --mirror . "$BACKUP_DIR"
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
  log_info "Rewriting history to remove target files..."

  local f
  for f in "${SECRET_FILES[@]}"; do
    if git log --all --full-history -- "$f" --oneline --quiet 2>/dev/null | grep -q .; then
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
  log_info "Verifying target files removed from history..."

  local found=0
  local f
  for f in "${SECRET_FILES[@]}"; do
    local commits
    commits=$(git log --all --full-history -- "$f" --oneline 2>/dev/null || true)
    if [ -n "$commits" ]; then
      log_error "FAILED: $f still exists in history!"
      found=1
    fi
  done

  if [[ "$found" -eq 0 ]]; then
    log_ok "Verified: all target files removed from history."
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

  # Check for GPG key
  if command -v gpg &>/dev/null && gpg --list-secret-keys --keyid-format=long 2>/dev/null | grep -q sec; then
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

  log_info "This will re-sign ALL commits on the current branch."
  if ! prompt_yes_no "Proceed with re-signing?"; then
    log_info "Skipping re-sign."
    return 1
  fi

  # Stash any uncommitted changes
  local had_changes=false
  if ! git diff-index --quiet HEAD -- 2>/dev/null; then
    log_info "Stashing uncommitted changes before re-signing..."
    git stash push -m "auto-purge-secret: temp stash"
    had_changes=true
  fi

  # Rebase from root, signing each commit
  if [[ "$sign_key" == "ssh" ]]; then
    GIT_COMMITTER_DATE="$(date)" git rebase --root --exec 'git commit --amend --no-edit -S'
  else
    GIT_COMMITTER_DATE="$(date)" git rebase --root --exec "git commit --amend --no-edit -S$sign_key"
  fi

  # Restore stashed changes
  if [[ "$had_changes" == true ]]; then
    log_info "Restoring stashed changes..."
    git stash pop || log_warn "Stash pop had conflicts. Resolve with: git stash pop"
  fi

  log_ok "All commits re-signed."
}

# ---------------------------------------------------------------------------
# Force Push
# ---------------------------------------------------------------------------
force_push() {
  [[ "$NO_PUSH" == true ]] && { log_info "Push skipped (--no-push)."; return; }

  log_warn "Ready to force-push rewritten history to the remote."
  log_warn "This will overwrite remote history. All collaborators MUST re-clone."

  if ! prompt_yes_no "Force-push to origin?"; then
    log_info "Skipping push. Push manually later with:"
    log_info "  git push origin --force --all"
    log_info "  git push origin --force --tags"
    return
  fi

  local remote="origin"
  if ! git remote | grep -q '^origin$'; then
    remote=$(git remote | head -1)
    [[ -z "$remote" ]] && { log_error "No remote configured."; return; }
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

  local report_file="./gitleaks-report.json"

  if command -v gitleaks &>/dev/null; then
    gitleaks detect --source . --report-format json --report-path "$report_file" 2>/dev/null || true
  elif command -v docker &>/dev/null; then
    docker run --rm -v "$(pwd):/src" zricethezav/gitleaks:latest detect --source /src --report-format json --report-path /src/gitleaks-report.json 2>/dev/null || true
  else
    log_warn "Neither gitleaks nor docker found. Skipping validation scan."
    return
  fi

  local leak_count=0
  if [[ -f "$report_file" ]]; then
    leak_count=$(jq 'length' "$report_file" 2>/dev/null || echo 0)
  fi

  if [[ "$leak_count" -eq 0 ]]; then
    log_ok "Gitleaks scan clean: 0 leaks found."
  else
    log_warn "Gitleaks still reports $leak_count leak(s). Review $report_file"
  fi
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
print_summary() {
  echo ""
  echo "============================================================"
  log_ok "Secret purge complete!"
  echo "============================================================"
  echo ""
  echo "Summary:"
  [[ "$NO_BACKUP" != true ]] && echo "  - Backup:        $BACKUP_DIR"
  echo "  - Target files:  ${#SECRET_FILES[@]} purged from history"
  echo "  - Gitleaks scan: Check gitleaks-report.json"
  echo ""
  echo "Next steps:"
  echo "  1. Verify: git log --oneline"
  echo "  2. If you did not force-push, run: git push origin --force --all"
  echo "  3. Notify all collaborators to re-clone the repository"
  echo "  4. Rotate any exposed secrets in deployed systems"
  echo "  5. Consider adding .gitleaks.toml for baseline/allowlist config"
  echo ""
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  parse_args "$@"
  load_config

  echo ""
  echo "============================================================"
  echo "  Universal Git Secret History Purge"
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

  # Auto-detect if requested
  if [[ "$AUTO_DETECT" == true ]]; then
    auto_detect_secrets || true
  fi

  # Resolve patterns
  resolve_patterns

  # Deduplicate and validate
  deduplicate_targets

  # Create backup
  create_backup

  # Detect signed commits
  local has_signed=false
  if detect_signed_commits; then
    has_signed=true
  fi

  # Rewrite history
  rewrite_history

  # Verify removal
  verify_removal

  # Handle signatures
  if [[ "$FORCE_SIGN" == true ]]; then
    resign_commits || log_warn "Re-signing failed or was skipped."
  elif [[ "$has_signed" == true && "$NO_SIGN" != true ]]; then
    echo ""
    log_info "Your repository contains signed commits."
    echo ""
    echo "Options:"
    echo "  1) Re-sign all rewritten commits"
    echo "  2) Accept unsigned history, sign future commits"
    echo "  3) Skip (keep unsigned)"
    echo ""

    local choice
    read -rp "Choose an option [1-3]: " choice

    case "$choice" in
      1) resign_commits || log_warn "Re-signing skipped or failed." ;;
      2) log_info "Historical commits will remain unsigned. Sign future commits." ;;
      3) log_info "Skipping re-sign." ;;
      *) log_warn "Invalid choice. Skipping re-sign." ;;
    esac
  fi

  # Final validation
  echo ""
  log_info "Final verification..."
  verify_removal
  rescan_gitleaks

  # Push
  echo ""
  force_push

  # Summary
  print_summary
}

main "$@"
