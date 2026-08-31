# Centralized fork sync

This repository contains a centralized script and workflow to synchronize your forks with their upstream repositories:
- `sync-forks.sh` — main script. Lists forks, clones each fork, creates a branch from the upstream default branch, pushes it to the fork, opens a PR and **auto-merges it** when there are no conflicts.
- `.github/workflows/sync-forks.yml` — CI that runs the script on schedule (or manually).

How it works
1. For each fork the script detects the upstream (parent) repository and its default branch.
2. A sync branch `update/upstream-YYYYMMDD` is created from the upstream default branch and pushed to the fork.
3. A PR is opened against the fork's default branch (`main`).
4. If GitHub reports the PR as mergeable (no conflicts), it is **merged automatically** and the sync branch is deleted.
5. If there are conflicts, the PR stays open for manual review.
6. After a successful merge, all stale `update/upstream-*` branches are cleaned up in the fork.

Quick setup
1. Add files above to the repository root and commit.
2. Create a Personal Access Token (PAT) with `repo` scope:
   - Go to GitHub → Settings → Developer settings → Personal access tokens → Generate new token.
   - Give it `repo` (write) scope so it can push to your forks and create PRs.
3. In this repo: Settings → Secrets and variables → Actions → New repository secret:
   - Name: `MAINTAINER_TOKEN`
   - Value: the PAT from step 2.
4. (Optional) Edit `.github/workflows/sync-forks.yml` to change cron or the script arguments.

Testing / dry-run
- Locally:
  - Install required tools (gh CLI, git, jq).
  - Export token: `export MAINTAINER_TOKEN="YOUR_PAT"`
  - Run: `./sync-forks.sh --user art-over-group --dry-run`
- In Actions:
  - Temporarily change the run step to: `./sync-forks.sh --user art-over-group --parallel 4 --dry-run`
  - Run the workflow manually via Actions → Run workflow.

Customization
- To target a specific list of forks, create a file `my_forks.txt` with `owner/repo` per line and run `./sync-forks.sh --user art-over-group --repos-file my_forks.txt`.
- Change `--parallel` value for concurrency.
- The script creates PRs in each fork repository; you can add labels/reviewers by enhancing the `gh pr create` call.

Security notes
- Keep the PAT secret and do not expose it.
- The PAT must belong to an account that has push rights to the forks (ideally your account).
- Auto-merge is applied only when GitHub reports the PR as conflict-free; conflicting PRs stay open for manual review.
- If you prefer manual review for everything, remove the `gh pr merge` block from `sync-forks.sh`.

Troubleshooting
- `Push failed for <fork>` — check that the PAT has `repo` scope and belongs to an account with push access to the forks.
- `No upstream parent detected` — the repository is not a fork; it is skipped automatically.
- Parallel mode requires bash; the script exports `process_fork` for `xargs` workers automatically.
