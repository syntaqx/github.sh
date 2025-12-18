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
# Maximum number of parallel jobs (can be overridden by setting MAX_PARALLEL_JOBS environment variable)
MAX_PARALLEL_JOBS=${MAX_PARALLEL_JOBS:-5}
# Array to track failed repositories
declare -a FAILED_REPOS
FAILED_REPOS_FILE="/tmp/github_failed_repos_$$.tmp"

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

# Output organization clone directory
echo "Cloning repositories to: $(realpath "$PWD")"
echo "Using up to $MAX_PARALLEL_JOBS parallel jobs"

# Function to fetch repositories from the GitHub API
fetch_repositories() {
  curl -s -H "Authorization: token $GITHUB_TOKEN" "$GITHUB_API_URL/orgs/$ORG/repos?per_page=$PER_PAGE&page=$PAGE"
}

# Function to check if a repository should be ignored
should_ignore() {
  local repo_name=$1
  for ignored in "${IGNORE_LIST[@]}"; do
    if [[ "$repo_name" == "$ignored" ]]; then
      return 0  # true, should ignore
    fi
  done
  return 1  # false, should not ignore
}

# Function to ensure remote is using SSH
ensure_ssh_remote() {
  # Get the current remote URL
  local remote_url
  remote_url=$(git remote get-url origin)

  # Check if it's an HTTPS URL
  if [[ $remote_url == https://github.com/* ]]; then
    # Convert HTTPS URL to SSH URL
    local ssh_url="git@github.com:${remote_url#https://github.com/}"

    # Update the remote URL
    if [ "$VERBOSE" = true ]; then
      echo "Converting remote from HTTPS to SSH: $remote_url → $ssh_url"
      git remote set-url origin "$ssh_url"
    else
      git remote set-url origin "$ssh_url" &> /dev/null
    fi
  fi
}

# Function to process a single repository
process_repository() {
  local REPO=$1
  local REPO_DIR
  REPO_DIR=$(basename "$REPO" .git)
  REPO_DIR="${REPO_DIR%.git}"

  if [ -d "$REPO_DIR" ]; then
    echo "Directory $REPO_DIR exists. Pulling latest changes..."
    cd "$REPO_DIR" || { echo "Failed to change directory to $REPO_DIR"; return 1; }
    # Ensure remote is using SSH before pulling
    ensure_ssh_remote

    # Checkout main branch before pulling
    local pull_status=0
    if [ "$VERBOSE" = true ]; then
      echo "Checking out main branch for $REPO_DIR..."
      git checkout main 2>/dev/null || git checkout master 2>/dev/null || echo "Warning: Could not checkout main/master branch for $REPO_DIR"
      git remote -v
      git pull
      pull_status=$?
    else
      git checkout main 2>/dev/null || git checkout master 2>/dev/null
      git pull --quiet
      pull_status=$?
    fi
    cd .. || { echo "Failed to change back to parent directory"; return 1; }

    # Check if pull failed
    if [ $pull_status -ne 0 ]; then
      echo "ERROR: Failed to pull $REPO_DIR (exit code: $pull_status)"
      echo "$REPO_DIR:$pull_status" >> "$FAILED_REPOS_FILE"
      return 1
    fi
  else
    echo "Cloning repository $REPO_DIR..."
    local clone_status=0
    if [ "$VERBOSE" = true ]; then
      git clone "$REPO"
      clone_status=$?
    else
      git clone --quiet "$REPO"
      clone_status=$?
    fi

    # Check if clone failed
    if [ $clone_status -ne 0 ]; then
      echo "ERROR: Failed to clone $REPO_DIR (exit code: $clone_status)"
      echo "$REPO_DIR:$clone_status" >> "$FAILED_REPOS_FILE"
      return 1
    fi
  fi

  # Signal completion
  echo "Completed processing $REPO_DIR"
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

# Fetch and clone all repositories
while true; do
  echo "-----------------------------------------"
  echo "Fetching page $PAGE of repositories..."
  REPOS=$(fetch_repositories)
  REPO_NAMES=$(echo "$REPOS" | jq -r '.[].ssh_url')

  if [ -z "$REPO_NAMES" ] || [ "$REPO_NAMES" == "null" ]; then
    echo "No more repositories found."
    break
  fi

  for REPO in $REPO_NAMES; do
    # Get repository name
    repo_name=$(basename "$REPO" .git)

    # Check if repository should be ignored
    if should_ignore "$repo_name"; then
      echo "⏭️  Skipping ignored repository: $repo_name"
      SKIPPED_REPOS=$((SKIPPED_REPOS + 1))
      continue
    fi

    # Wait if we've reached the maximum number of parallel jobs
    wait_for_jobs $MAX_PARALLEL_JOBS

    # Process repository in background
    process_repository "$REPO" &

    TOTAL_REPOS=$((TOTAL_REPOS + 1))
  done

  PAGE=$((PAGE + 1))
done

# Wait for all remaining background jobs to complete
echo "Waiting for all repositories to finish processing..."
wait

# Check for any failures
if [ -f "$FAILED_REPOS_FILE" ]; then
  while IFS=: read -r repo_name exit_code; do
    FAILED_REPOS+=("$repo_name (exit code: $exit_code)")
  done < "$FAILED_REPOS_FILE"
  rm -f "$FAILED_REPOS_FILE"
fi

echo "-----------------------------------------"
echo "All repositories have been cloned or updated."
echo "Total repositories processed: $TOTAL_REPOS"
if [ $SKIPPED_REPOS -gt 0 ]; then
  echo "Skipped repositories (ignored): $SKIPPED_REPOS"
fi

# Report any failures
if [ ${#FAILED_REPOS[@]} -gt 0 ]; then
  echo ""
  echo "⚠️  WARNING: ${#FAILED_REPOS[@]} repository/repositories encountered errors:"
  for failed in "${FAILED_REPOS[@]}"; do
    echo "  ❌ $failed"
  done
  echo ""
  echo "Please manually fix the repositories listed above."
else
  echo "✅ All repositories processed successfully."
fi
