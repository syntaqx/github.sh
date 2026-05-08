#!/bin/bash

# Check if GitHub organization is provided
if [ -z "$1" ]; then
  echo "Usage: $0 <github-organization> [-v|--verbose]"
  exit 1
fi

# Check if GITHUB_TOKEN is set
if [ -z "$GITHUB_TOKEN" ]; then
  echo "Error: GITHUB_TOKEN is not set in the environment."
  exit 1
fi

# Parse arguments
ORG=$1
VERBOSE=false
if [[ "$2" == "-v" || "$2" == "--verbose" ]]; then
  VERBOSE=true
fi

GITHUB_API_URL="https://api.github.com"
PAGE=1
PER_PAGE=100
ORG_DIR=$ORG
TOTAL_REPOS=0
SKIPPED_REPOS=0
SYNCED_REPOS=0
CLONED_REPOS=0
MAX_PARALLEL_JOBS=${MAX_PARALLEL_JOBS:-5}
declare -a FAILED_REPOS
FAILED_REPOS_FILE="/tmp/github_failed_repos_$$.tmp"
SUCCESS_FILE="/tmp/github_success_$$.tmp"

# Repositories to ignore (add repository names here)
declare -a IGNORE_LIST=(
  "customer-portal-deprecated"
  "sdk-js-legacy"
  "legacy-ops-traefik"
  "ops-seeder"
)

# Create organization directory if it doesn't exist
mkdir -p "$ORG_DIR"
cd "$ORG_DIR" || { echo "Failed to change directory to $ORG_DIR"; exit 1; }

echo "⟳  Syncing $ORG → $(realpath "$PWD")"
echo ""

# Function to fetch repositories from the GitHub API
fetch_repositories() {
  curl -s -H "Authorization: token $GITHUB_TOKEN" "$GITHUB_API_URL/orgs/$ORG/repos?per_page=$PER_PAGE&page=$PAGE"
}

# Function to check if a repository should be ignored
should_ignore() {
  local repo_name=$1
  for ignored in "${IGNORE_LIST[@]}"; do
    if [[ "$repo_name" == "$ignored" ]]; then
      return 0
    fi
  done
  return 1
}

# Function to ensure remote is using SSH
ensure_ssh_remote() {
  local remote_url
  remote_url=$(git remote get-url origin)
  if [[ $remote_url == https://github.com/* ]]; then
    local ssh_url="git@github.com:${remote_url#https://github.com/}"
    git remote set-url origin "$ssh_url" &> /dev/null
  fi
}

# Function to process a single repository
process_repository() {
  local REPO=$1
  local REPO_DIR
  REPO_DIR=$(basename "$REPO" .git)
  REPO_DIR="${REPO_DIR%.git}"

  if [ -d "$REPO_DIR" ]; then
    cd "$REPO_DIR" || return 1
    ensure_ssh_remote

    # Detect dirty working tree
    local dirty=false
    if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
      dirty=true
    fi

    # Checkout main/master
    local branch
    branch=$(git checkout main 2>/dev/null && echo "main" || (git checkout master 2>/dev/null && echo "master"))

    # Pull
    local output pull_status
    output=$(git pull --quiet 2>&1)
    pull_status=$?
    cd ..

    if [ $pull_status -ne 0 ]; then
      local reason="unknown"
      if [ "$dirty" = true ]; then
        reason="dirty"
      elif echo "$output" | grep -q "unrelated histories"; then
        reason="diverged"
      elif echo "$output" | grep -q "no such ref"; then
        reason="missing-ref"
      fi
      echo "  ✗ $REPO_DIR"
      echo "$REPO_DIR:$pull_status:$reason" >> "$FAILED_REPOS_FILE"
      return 1
    fi

    echo "  ✓ $REPO_DIR"
    echo "pull" >> "$SUCCESS_FILE"
  else
    local output clone_status
    output=$(git clone --quiet "$REPO" 2>&1)
    clone_status=$?

    if [ $clone_status -ne 0 ]; then
      echo "  ✗ $REPO_DIR (clone failed)"
      echo "$REPO_DIR:$clone_status:clone" >> "$FAILED_REPOS_FILE"
      return 1
    fi

    echo "  + $REPO_DIR (cloned)"
    echo "clone" >> "$SUCCESS_FILE"
  fi

  return 0
}

# Function to wait for background jobs to complete
wait_for_jobs() {
  local max_jobs=$1
  local job_count
  job_count=$(jobs -r | wc -l)
  while [ "$job_count" -ge "$max_jobs" ]; do
    sleep 0.1
    job_count=$(jobs -r | wc -l)
  done
}

# Clean up temp files
rm -f "$FAILED_REPOS_FILE" "$SUCCESS_FILE"

# Fetch and process all repositories
while true; do
  REPOS=$(fetch_repositories)
  REPO_NAMES=$(echo "$REPOS" | jq -r '.[].ssh_url')

  if [ -z "$REPO_NAMES" ] || [ "$REPO_NAMES" == "null" ]; then
    break
  fi

  for REPO in $REPO_NAMES; do
    repo_name=$(basename "$REPO" .git)

    if should_ignore "$repo_name"; then
      SKIPPED_REPOS=$((SKIPPED_REPOS + 1))
      continue
    fi

    wait_for_jobs $MAX_PARALLEL_JOBS
    process_repository "$REPO" &
    TOTAL_REPOS=$((TOTAL_REPOS + 1))
  done

  PAGE=$((PAGE + 1))
done

wait

# Count successes
if [ -f "$SUCCESS_FILE" ]; then
  SYNCED_REPOS=$(grep -c "pull" "$SUCCESS_FILE" 2>/dev/null || echo 0)
  CLONED_REPOS=$(grep -c "clone" "$SUCCESS_FILE" 2>/dev/null || echo 0)
  rm -f "$SUCCESS_FILE"
fi

# Collect failures
declare -a DIRTY_REPOS
declare -a OTHER_FAILURES

if [ -f "$FAILED_REPOS_FILE" ]; then
  while IFS=: read -r repo_name exit_code reason; do
    if [[ "$reason" == "dirty" ]]; then
      DIRTY_REPOS+=("$repo_name")
    else
      OTHER_FAILURES+=("$repo_name ($reason)")
    fi
    FAILED_REPOS+=("$repo_name")
  done < "$FAILED_REPOS_FILE"
  rm -f "$FAILED_REPOS_FILE"
fi

# Summary
echo ""
echo "── done ─────────────────────────────────"
echo "  $SYNCED_REPOS synced · $CLONED_REPOS cloned · ${#FAILED_REPOS[@]} failed · $SKIPPED_REPOS ignored"

# Report non-dirty failures
if [ ${#OTHER_FAILURES[@]} -gt 0 ]; then
  echo ""
  echo "  Failed (manual fix needed):"
  for failed in "${OTHER_FAILURES[@]}"; do
    echo "    ✗ $failed"
  done
fi

# Handle dirty repos interactively
if [ ${#DIRTY_REPOS[@]} -gt 0 ]; then
  echo ""
  echo "  Failed (local changes):"
  for repo in "${DIRTY_REPOS[@]}"; do
    echo "    ✗ $repo"
  done
  echo ""
  read -r -p "  Reset these ${#DIRTY_REPOS[@]} repo(s) with git reset --hard and retry? [y/N] " response
  if [[ "$response" =~ ^[Yy]$ ]]; then
    echo ""
    for repo in "${DIRTY_REPOS[@]}"; do
      cd "$repo" || continue
      git reset --hard HEAD --quiet 2>/dev/null
      git checkout main 2>/dev/null || git checkout master 2>/dev/null
      if git pull --quiet 2>/dev/null; then
        echo "  ✓ $repo (reset + pulled)"
      else
        echo "  ✗ $repo (still failing after reset)"
      fi
      cd ..
    done
  fi
fi

if [ ${#FAILED_REPOS[@]} -eq 0 ]; then
  echo ""
  echo "  ✓ All repos up to date."
fi
