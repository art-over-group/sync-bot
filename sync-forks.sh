#!/usr/bin/env bash
# Centralized fork sync script.
# Requires: gh (GitHub CLI), git, jq
# Usage examples:
#  ./sync-forks.sh --user art-over-group        # process all forks of user
#  ./sync-forks.sh --user art-over-group --repos-file my_forks.txt
#  ./sync-forks.sh --user art-over-group --dry-run

set -euo pipefail
IFS=$'\n\t'

# Defaults
USER=""
REPOS_FILE=""
DRY_RUN=false
PARALLEL=1
TMPDIR=$(mktemp -d)
PR_TITLE_TEMPLATE="chore(sync): update from upstream/{UPSTREAM_BRANCH}"
PR_BODY_TEMPLATE="Automated sync from upstream repository {UPSTREAM_FULL} ({UPSTREAM_BRANCH}) on {DATE}."
BRANCH_PREFIX="update/upstream"
GH_CLI_TOKEN_ENV="MAINTAINER_TOKEN"

function usage() {
  cat <<EOF
Usage: $0 --user <github-username> [--repos-file <file>] [--dry-run] [--parallel N]

Options:
  --user USER            GitHub username whose forks to process (required)
  --repos-file FILE      File with newline-separated fork full names (owner/repo). If omitted, script lists user's forks via gh.
  --dry-run              Don't push or create PRs; just show what would be done.
  --parallel N           Number of parallel workers (default 1).
Environment:
  Export $GH_CLI_TOKEN_ENV with a PAT that has 'repo' scope (write access to your forks).
Requirements:
  gh (GitHub CLI), git, jq
EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user) USER="$2"; shift 2;;
    --repos-file) REPOS_FILE="$2"; shift 2;;
    --dry-run) DRY_RUN=true; shift;;
    --parallel) PARALLEL="$2"; shift 2;;
    --help) usage;;
    *) echo "Unknown arg: $1"; usage;;
  esac
done

if [[ -z "$USER" ]]; then
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

declare -a FORKS=()
if [[ -n "$REPOS_FILE" ]]; then
  mapfile -t FORKS < "$REPOS_FILE"
else
  echo "Listing forks for user $USER..."
  PAGE=1
  while true; do
    out=$(gh api -H "Accept: application/vnd.github+json" "/users/${USER}/repos?type=forks&per_page=100&page=${PAGE}")
    if [[ $(echo "$out" | jq 'length') -eq 0 ]]; then
      break
    fi
    mapfile -t page_forks < <(echo "$out" | jq -r '.[].full_name')
    FORKS+=("${page_forks[@]})
    ((PAGE++))
  done
fi

if [[ ${#FORKS[@]} -eq 0 ]]; then
  echo "No forks found for user ${USER}."
  exit 0
fi

echo "Found ${#FORKS[@]} fork(s) to process."
DATE=$(date -u +%Y-%m-%d)

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

  upstream_default_branch=$(gh api -H "Accept: application/vnd.github+json" "/repos/${parent_full}" | jq -r '.default_branch // "main"')
  echo "Upstream: ${parent_full} (branch: ${upstream_default_branch}), fork default branch: ${fork_default_branch}"

  WORKDIR="${TMPDIR}/$(echo $fork_full | tr / -)-${RANDOM}"
  mkdir -p "$WORKDIR"
  git clone --depth=1 "https://github.com/${fork_full}.git" "$WORKDIR" || { echo "Clone failed for ${fork_full}"; rm -rf "$WORKDIR"; return; }
  pushd "$WORKDIR" >/dev/null

  git remote add upstream "https://github.com/${parent_full}.git" 2>/dev/null || true
  git fetch upstream --depth=1 || { echo "Failed to fetch upstream for ${fork_full}"; popd >/dev/null; rm -rf "$WORKDIR"; return; }

  BRANCH="${BRANCH_PREFIX}-$(date -u +%Y%m%d)"

  git checkout -b "$BRANCH" "upstream/${upstream_default_branch}" || { echo "Failed to checkout upstream branch for ${fork_full}"; popd >/dev/null; rm -rf "$WORKDIR"; return; }

  if $DRY_RUN; then
    echo "[dry-run] Would push branch ${BRANCH} to ${fork_full} and create PR."
    popd >/dev/null
    rm -rf "$WORKDIR"
    return
  fi

  echo "Pushing branch ${BRANCH} -> origin"
  git push --set-upstream origin "$BRANCH" -q || { echo "Push failed for ${fork_full}"; popd >/dev/null; rm -rf "$WORKDIR"; return; }

  owner=$(echo "$fork_full" | cut -d/ -f1)
  existing_prs=$(gh pr list --repo "$fork_full" --head "${owner}:${BRANCH}" --state open --json number --jq '.[].number' || true)
  if [[ -n "$existing_prs" ]]; then
    echo "An open PR already exists for ${fork_full} branch ${BRANCH}: ${existing_prs}. Skipping PR creation."
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
  gh pr create --repo "$fork_full" --head "${owner}:${BRANCH}" --base "$fork_default_branch" --title "$PR_TITLE" --body "$PR_BODY" >/dev/null || echo "Failed to create PR for ${fork_full}"

  popd >/dev/null
  rm -rf "$WORKDIR"
}

if [[ "$PARALLEL" -gt 1 ]]; then
  printf "%s\n" "${FORKS[@]}" | xargs -n1 -P "$PARALLEL" -I{} bash -c 'process_fork "$@"' _ {}
else
  for f in "${FORKS[@]}"; do
    process_fork "$f"
  done
fi

echo "All done."
rm -rf "$TMPDIR"
