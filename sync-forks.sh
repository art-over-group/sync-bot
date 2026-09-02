#!/usr/bin/env bash
# Centralized fork sync script.
# Requires: gh (GitHub CLI), git, jq
# Usage examples:
#  ./sync-forks.sh --user art-over-group        # process all forks of user
#  ./sync-forks.sh --user art-over-group --repos-file my_forks.txt
#  ./sync-forks.sh --user art-over-group --dry-run
#  ./sync-forks.sh --user art-over-group --direct-push  # update main branch directly (no PR)

set -euo pipefail
IFS=$'\n\t'

# Defaults
GH_USER=""
REPOS_FILE=""
DRY_RUN=false
PARALLEL=1
DIRECT_PUSH=false
WORKROOT=$(mktemp -d)
PR_TITLE_TEMPLATE="chore(sync): update from upstream/{UPSTREAM_BRANCH}"
PR_BODY_TEMPLATE="Automated sync from upstream repository {UPSTREAM_FULL} ({UPSTREAM_BRANCH}) on {DATE}."
BRANCH_PREFIX="update/upstream"
GH_CLI_TOKEN_ENV="MAINTAINER_TOKEN"

function usage() {
  cat <<EOF
Usage: $0 --user <github-username> [--repos-file <file>] [--dry-run] [--parallel N] [--direct-push]

Options:
  --user USER            GitHub username whose forks to process (required)
  --repos-file FILE      File with newline-separated fork full names (owner/repo). If omitted, script lists user's forks via gh.
  --dry-run              Don't push or create PRs; just show what would be done.
  --parallel N           Number of parallel workers (default 1).
  --direct-push          Update the default branch directly instead of creating PRs (faster sync, no PR review).
Environment:
  Export $GH_CLI_TOKEN_ENV with a PAT that has 'repo' scope (write access to your forks).
Requirements:
  gh (GitHub CLI), git, jq
EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user) GH_USER="$2"; shift 2;;
    --repos-file) REPOS_FILE="$2"; shift 2;;
    --dry-run) DRY_RUN=true; shift;;
    --direct-push) DIRECT_PUSH=true; shift;;
    --parallel) PARALLEL="$2"; shift 2;;
    --help) usage;;
    *) echo "Unknown arg: $1"; usage;;
  esac
done

if [[ -z "$GH_USER" ]]; then
  echo "Missing --user"
  usage
fi

for cmd in gh git jq; do
  if ! command -v $cmd >/dev/null 2>&1; then
    echo "$cmd CLI not found. Install it before running."
    exit 2
  fi
done

if [[ -z "${!GH_CLI_TOKEN_ENV:-}" ]]; then
  echo "Set env ${GH_CLI_TOKEN_ENV} to a PAT with repo scope (write access to your forks)."
  exit 2
fi

export GITHUB_TOKEN="${!GH_CLI_TOKEN_ENV}"

# Basic-auth header for authenticated git push (the token never appears in URLs or logs)
AUTH_HEADER="Authorization: Basic $(printf 'x-access-token:%s' "$GITHUB_TOKEN" | base64 | tr -d '\n')"
export AUTH_HEADER

declare -a FORKS=()
if [[ -n "$REPOS_FILE" ]]; then
  if [[ ! -f "$REPOS_FILE" ]]; then
    echo "Repos file not found: $REPOS_FILE"
    exit 2
  fi
  mapfile -t FORKS < "$REPOS_FILE"
else
  echo "Listing forks for user $GH_USER..."
  PAGE=1
  while true; do
    out=$(gh api -H "Accept: application/vnd.github+json" "/users/${GH_USER}/repos?type=forks&per_page=100&page=${PAGE}")
    if [[ $(echo "$out" | jq 'length') -eq 0 ]]; then
      break
    fi
    mapfile -t page_forks < <(echo "$out" | jq -r '.[].full_name')
    FORKS+=("${page_forks[@]}")
    PAGE=$((PAGE + 1))
  done
fi

if [[ ${#FORKS[@]} -eq 0 ]]; then
  echo "No forks found for user ${GH_USER}."
  exit 0
fi

echo "Found ${#FORKS[@]} fork(s) to process."
DATE=$(date -u +%Y-%m-%d)

# Delete all stale sync branches (update/upstream-*) in the fork.
# Called only after a successful merge or when the fork is already up to date.
function cleanup_old_branches() {
  local fork_full="$1"
  local branches b
  branches=$(gh api "/repos/${fork_full}/branches?per_page=100" --jq '.[].name' 2>/dev/null | grep "^${BRANCH_PREFIX}-" || true)
  if [[ -z "$branches" ]]; then
    return
  fi
  while IFS= read -r b; do
    [[ -z "$b" ]] && continue
    echo "Deleting stale sync branch ${b} in ${fork_full}"
    gh api -X DELETE "/repos/${fork_full}/git/refs/heads/${b}" >/dev/null 2>&1 || echo "WARNING: failed to delete branch ${b} in ${fork_full}."
  done <<< "$branches"
}

# Export variables used by process_fork in parallel workers (xargs spawns new shells)
export WORKROOT DATE DRY_RUN BRANCH_PREFIX PR_TITLE_TEMPLATE PR_BODY_TEMPLATE DIRECT_PUSH

function process_fork() {
  local fork_full="$1"
  echo "----"
  echo "Processing fork: $fork_full"

  repo_json=$(gh api -H "Accept: application/vnd.github+json" "/repos/${fork_full}" || true)
  if [[ -z "$repo_json" ]]; then
    echo "Failed to fetch metadata for ${fork_full}, skipping."
    return
  fi

  parent_full=$(echo "$repo_json" | jq -r '.parent.full_name // empty')
  fork_default_branch=$(echo "$repo_json" | jq -r '.default_branch // "main"')

  if [[ -z "$parent_full" ]]; then
    echo "No upstream parent detected for ${fork_full}, skipping."
    return
  fi

  upstream_default_branch=$(gh api -H "Accept: application/vnd.github+json" "/repos/${parent_full}" | jq -r '.default_branch // "main"') || true
  if [[ -z "$upstream_default_branch" ]]; then
    upstream_default_branch="main"
  fi
  echo "Upstream: ${parent_full} (branch: ${upstream_default_branch}), fork default branch: ${fork_default_branch}"

  WORKDIR="${WORKROOT}/$(echo "$fork_full" | tr / -)-${RANDOM}"
  mkdir -p "$WORKDIR"
  git clone --depth=1 "https://github.com/${fork_full}.git" "$WORKDIR" || { echo "Clone failed for ${fork_full}"; rm -rf "$WORKDIR"; return; }
  pushd "$WORKDIR" >/dev/null

  git remote add upstream "https://github.com/${parent_full}.git" 2>/dev/null || true
  git fetch upstream --depth=1 || { echo "Failed to fetch upstream for ${fork_full}"; popd >/dev/null; rm -rf "$WORKDIR"; return; }

  if $DRY_RUN; then
    if $DIRECT_PUSH; then
      echo "[dry-run] Would directly push ${upstream_default_branch} to ${fork_full}/${fork_default_branch}."
    else
      echo "[dry-run] Would create branch and PR for ${fork_full}."
    fi
    popd >/dev/null
    rm -rf "$WORKDIR"
    return
  fi

  # ===== DIRECT PUSH MODE =====
  if $DIRECT_PUSH; then
    echo "Direct push mode: updating ${fork_default_branch} directly from upstream/${upstream_default_branch}..."
    
    # Get the commit SHA of upstream default branch
    upstream_sha=$(git rev-parse "upstream/${upstream_default_branch}")
    fork_sha=$(git rev-parse "origin/${fork_default_branch}" 2>/dev/null || echo "")
    
    if [[ "$upstream_sha" == "$fork_sha" ]]; then
      echo "${fork_full} is already up to date with upstream (both at ${upstream_sha:0:7})."
      cleanup_old_branches "$fork_full"
      popd >/dev/null
      rm -rf "$WORKDIR"
      return
    fi
    
    echo "Updating ${fork_full}/${fork_default_branch}: ${fork_sha:0:7} → ${upstream_sha:0:7}"
    if git -c http.extraHeader="$AUTH_HEADER" push origin "upstream/${upstream_default_branch}:${fork_default_branch}" --force -q; then
      echo "✅ Successfully updated ${fork_full}/${fork_default_branch}"
      cleanup_old_branches "$fork_full"
    else
      echo "❌ Failed to push to ${fork_full}/${fork_default_branch}"
    fi
    
    popd >/dev/null
    rm -rf "$WORKDIR"
    return
  fi

  # ===== PR MODE (original behavior) =====
  BRANCH="${BRANCH_PREFIX}-$(date -u +%Y%m%d)"

  git checkout -b "$BRANCH" "upstream/${upstream_default_branch}" || { echo "Failed to checkout upstream branch for ${fork_full}"; popd >/dev/null; rm -rf "$WORKDIR"; return; }

  echo "Pushing branch ${BRANCH} -> origin"
  git -c http.extraHeader="$AUTH_HEADER" push --force --set-upstream origin "$BRANCH" -q || { echo "Push failed for ${fork_full}"; popd >/dev/null; rm -rf "$WORKDIR"; return; }

  owner=$(echo "$fork_full" | cut -d/ -f1)
  existing_prs=$(gh pr list --repo "$fork_full" --head "${owner}:${BRANCH}" --state open --json number --jq '.[].number' || true)
  if [[ -n "$existing_prs" ]]; then
    echo "An open PR already exists for ${fork_full} branch ${BRANCH}: ${existing_prs}. Trying to merge it..."
    for pr_number in $existing_prs; do
      mergeable=$(gh pr view "$pr_number" --repo "$fork_full" --json mergeable --jq '.mergeable' 2>/dev/null || echo "UNKNOWN")
      if [[ "$mergeable" == "MERGEABLE" ]]; then
        if gh pr merge "$pr_number" --repo "$fork_full" --merge --delete-branch >/dev/null 2>&1; then
          echo "Merged existing PR #${pr_number} in ${fork_full}."
          cleanup_old_branches "$fork_full"
        else
          echo "WARNING: auto-merge failed for existing PR #${pr_number} in ${fork_full}. Left open."
        fi
      else
        echo "Existing PR #${pr_number} in ${fork_full} is not mergeable (conflicts). Left open for manual review."
      fi
    done
    popd >/dev/null
    rm -rf "$WORKDIR"
    return
  fi

  PR_TITLE=${PR_TITLE_TEMPLATE//\{UPSTREAM_BRANCH\}/${upstream_default_branch}}
  PR_TITLE=${PR_TITLE//\{UPSTREAM_FULL\}/${parent_full}}
  PR_TITLE=${PR_TITLE//\{DATE\}/${DATE}}
  PR_BODY=${PR_BODY_TEMPLATE//\{UPSTREAM_BRANCH\}/${upstream_default_branch}}
  PR_BODY=${PR_BODY//\{UPSTREAM_FULL\}/${parent_full}}
  PR_BODY=${PR_BODY//\{DATE\}/${DATE}}

  echo "Creating PR in ${fork_full}: ${PR_TITLE}"
  if ! pr_url=$(gh pr create --repo "$fork_full" --head "${owner}:${BRANCH}" --base "$fork_default_branch" --title "$PR_TITLE" --body "$PR_BODY" 2>/dev/null); then
    echo "Failed to create PR for ${fork_full}, leaving branch for manual review."
    popd >/dev/null
    rm -rf "$WORKDIR"
    return
  fi
  echo "PR created: ${pr_url}"

  # Auto-merge: only works when GitHub reports the PR as mergeable (no conflicts).
  pr_number=$(gh pr view --repo "$fork_full" --json number --jq '.number')
  mergeable=$(gh pr view "$pr_number" --repo "$fork_full" --json mergeable --jq '.mergeable')
  if [[ "$mergeable" == "MERGEABLE" ]]; then
    echo "Auto-merging PR #${pr_number} in ${fork_full}..."
    if gh pr merge "$pr_number" --repo "$fork_full" --merge --delete-branch >/dev/null 2>&1; then
      echo "Merged PR #${pr_number} in ${fork_full}."
      cleanup_old_branches "$fork_full"
    else
      echo "WARNING: auto-merge failed for ${fork_full} (branch protection or checks). PR left open: ${pr_url}"
    fi
  else
    echo "PR #${pr_number} in ${fork_full} has conflicts or is not mergeable yet. Left open for manual review: ${pr_url}"
  fi

  popd >/dev/null
  rm -rf "$WORKDIR"
}

# Make the functions visible to parallel worker shells
export -f process_fork
export -f cleanup_old_branches

if [[ "$PARALLEL" -gt 1 ]]; then
  printf "%s\n" "${FORKS[@]}" | xargs -n1 -P "$PARALLEL" -I{} bash -c 'process_fork "$@"' _ {} \
    || echo "WARNING: some forks failed to process."
else
  for f in "${FORKS[@]}"; do
    process_fork "$f" || echo "WARNING: failed to process ${f}."
  done
fi

echo "All done."
rm -rf "$WORKROOT"
