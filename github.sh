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
# Strip surrounding whitespace and any leading/trailing slashes (e.g. "aspyn-io/")
ORG=$(echo "$1" | sed -E 's#^[[:space:]/]+|[[:space:]/]+$##g')
if [ -z "$ORG" ]; then
  echo "Error: invalid organization name '$1'."
  exit 1
fi
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
RESULTS_FILE="/tmp/github_sync_$$.tmp"
COUNT_WIDTH=1

# Colors — automatically disabled when stdout is not a terminal (e.g. piped)
if [ -t 1 ]; then
  BOLD=$'\e[1m'; DIM=$'\e[2m'; RESET=$'\e[0m'
  RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'
  BLUE=$'\e[34m'; MAGENTA=$'\e[35m'; CYAN=$'\e[36m'; GREY=$'\e[90m'
else
  BOLD=''; DIM=''; RESET=''
  RED=''; GREEN=''; YELLOW=''; BLUE=''; MAGENTA=''; CYAN=''; GREY=''
fi

# Braille spinner frames (array avoids multibyte substring pitfalls)
SPINNER=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')

# Print the ASCII banner
print_banner() {
  echo ""
  printf '%s\n' \
"${CYAN}   ____ _ _   ____                   ${RESET}" \
"${CYAN}  / ___(_) |_/ ___| _   _ _ __   ___ ${RESET}" \
"${CYAN} | |  _| | __\\___ \\| | | | '_ \\ / __|${RESET}" \
"${CYAN} | |_| | | |_ ___) | |_| | | | | (__ ${RESET}" \
"${CYAN}  \\____|_|\\__|____/ \\__, |_| |_|\\___|${RESET}" \
"${CYAN}                    |___/            ${RESET}"
  echo ""
  printf "  ${BOLD}%s${RESET} ${DIM}→ %s${RESET}\n\n" "$ORG" "$(realpath "$PWD")"
}

# Record a repo result and print a live [done/total] status line.
# Every job appends exactly one tab-separated line, so line count == progress.
# Args: <result> <reason> <color> <symbol> <name> <note>
report() {
  local result=$1 reason=$2 color=$3 symbol=$4 name=$5 note=$6 n
  printf '%s\t%s\t%s\n' "$result" "$name" "$reason" >> "$RESULTS_FILE"
  n=$(wc -l < "$RESULTS_FILE" 2>/dev/null); n=${n//[[:space:]]/}
  if [ -n "$note" ]; then
    printf "  ${GREY}[%*d/%d]${RESET} ${color}%s${RESET} %s ${DIM}%s${RESET}\n" \
      "$COUNT_WIDTH" "$n" "$TOTAL_REPOS" "$symbol" "$name" "$note"
  else
    printf "  ${GREY}[%*d/%d]${RESET} ${color}%s${RESET} %s\n" \
      "$COUNT_WIDTH" "$n" "$TOTAL_REPOS" "$symbol" "$name"
  fi
}

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

print_banner

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
      report fail "$reason" "$RED" "✗" "$REPO_DIR" "$reason"
      return 1
    fi

    report pull "" "$GREEN" "✓" "$REPO_DIR" ""
  else
    local output clone_status
    output=$(git clone --quiet "$REPO" 2>&1)
    clone_status=$?

    if [ $clone_status -ne 0 ]; then
      report fail "clone" "$RED" "✗" "$REPO_DIR" "clone failed"
      return 1
    fi

    report clone "" "$CYAN" "+" "$REPO_DIR" "cloned"
  fi

  return 0
}

# Block until a concurrency slot frees up. Uses `wait -n` on bash 4.3+ (blocks
# until the next job finishes); falls back to light polling on older shells.
wait_for_slot() {
  while [ "$(jobs -r | wc -l)" -ge "$MAX_PARALLEL_JOBS" ]; do
    wait -n 2>/dev/null || sleep 0.1
  done
}

# Clean up temp files
rm -f "$RESULTS_FILE"

# ── Phase 1: discover every repository up front ──────────────────────────
declare -a ALL_REPOS=()
spin_i=0

while true; do
  REPOS=$(fetch_repositories)
  REPO_NAMES=$(echo "$REPOS" | jq -r '.[].ssh_url')

  if [ -z "$REPO_NAMES" ] || [ "$REPO_NAMES" == "null" ]; then
    break
  fi

  while IFS= read -r REPO; do
    [ -z "$REPO" ] && continue
    ALL_REPOS+=("$REPO")
  done <<< "$REPO_NAMES"

  spin_i=$(( (spin_i + 1) % ${#SPINNER[@]} ))
  printf "\r  ${CYAN}%s${RESET} Discovering repositories… ${DIM}(%d found)${RESET}" \
    "${SPINNER[$spin_i]}" "${#ALL_REPOS[@]}"

  PAGE=$((PAGE + 1))
done

# Filter out ignored repos to build the work queue
declare -a REPO_QUEUE=()
for REPO in "${ALL_REPOS[@]}"; do
  repo_name=$(basename "$REPO" .git)
  if should_ignore "$repo_name"; then
    SKIPPED_REPOS=$((SKIPPED_REPOS + 1))
    continue
  fi
  REPO_QUEUE+=("$REPO")
done

TOTAL_REPOS=${#REPO_QUEUE[@]}
COUNT_WIDTH=${#TOTAL_REPOS}

printf "\r\033[K"
printf "  ${BOLD}%d${RESET} repositories  ${DIM}·${RESET}  ${GREEN}%d to sync${RESET}  ${DIM}·${RESET}  ${YELLOW}%d ignored${RESET}\n\n" \
  "${#ALL_REPOS[@]}" "$TOTAL_REPOS" "$SKIPPED_REPOS"

if [ "$TOTAL_REPOS" -eq 0 ]; then
  echo "  ${DIM}Nothing to sync.${RESET}"
  rm -f "$RESULTS_FILE"
  exit 0
fi

# ── Phase 2: sync (bounded concurrency, live [n/total] progress) ─────────
for REPO in "${REPO_QUEUE[@]}"; do
  wait_for_slot
  process_repository "$REPO" &
done

wait

# Tally results from the single results file (one tab-separated line per repo)
declare -a DIRTY_REPOS OTHER_FAILURES
if [ -f "$RESULTS_FILE" ]; then
  while IFS=$'\t' read -r result name reason; do
    case "$result" in
      pull)  SYNCED_REPOS=$((SYNCED_REPOS + 1)) ;;
      clone) CLONED_REPOS=$((CLONED_REPOS + 1)) ;;
      fail)
        FAILED_REPOS+=("$name")
        if [[ "$reason" == "dirty" ]]; then
          DIRTY_REPOS+=("$name")
        else
          OTHER_FAILURES+=("$name ($reason)")
        fi
        ;;
    esac
  done < "$RESULTS_FILE"
  rm -f "$RESULTS_FILE"
fi

# Summary
echo ""
printf "  ${DIM}%s${RESET}\n" "────────────────────────────────────────────"
printf "  ${GREEN}✓ %d synced${RESET}   ${CYAN}+ %d cloned${RESET}   ${RED}✗ %d failed${RESET}   ${YELLOW}⊘ %d ignored${RESET}\n" \
  "$SYNCED_REPOS" "$CLONED_REPOS" "${#FAILED_REPOS[@]}" "$SKIPPED_REPOS"

# Report non-dirty failures
if [ ${#OTHER_FAILURES[@]} -gt 0 ]; then
  echo ""
  printf "  ${BOLD}${RED}Failed${RESET} ${DIM}(manual fix needed)${RESET}\n"
  for failed in "${OTHER_FAILURES[@]}"; do
    printf "    ${RED}✗${RESET} %s\n" "$failed"
  done
fi

# Handle dirty repos interactively
if [ ${#DIRTY_REPOS[@]} -gt 0 ]; then
  echo ""
  printf "  ${BOLD}${YELLOW}Failed${RESET} ${DIM}(local changes)${RESET}\n"
  for repo in "${DIRTY_REPOS[@]}"; do
    printf "    ${YELLOW}✗${RESET} %s\n" "$repo"
  done
  echo ""
  read -r -p "  ${BOLD}Reset these ${#DIRTY_REPOS[@]} repo(s) with git reset --hard and retry? [y/N]${RESET} " response
  if [[ "$response" =~ ^[Yy]$ ]]; then
    echo ""
    for repo in "${DIRTY_REPOS[@]}"; do
      cd "$repo" || continue
      git reset --hard HEAD --quiet 2>/dev/null
      git checkout main 2>/dev/null || git checkout master 2>/dev/null
      if git pull --quiet 2>/dev/null; then
        printf "    ${GREEN}✓${RESET} %s ${DIM}(reset + pulled)${RESET}\n" "$repo"
      else
        printf "    ${RED}✗${RESET} %s ${DIM}(still failing after reset)${RESET}\n" "$repo"
      fi
      cd ..
    done
  fi
fi

if [ ${#FAILED_REPOS[@]} -eq 0 ]; then
  echo ""
  printf "  ${GREEN}✓ All repos up to date.${RESET}\n"
fi
