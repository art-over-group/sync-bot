# Centralized fork sync

This repository contains a centralized script and workflow to synchronize your forks with their upstream repositories:
- `sync-forks.sh` — main script. Lists forks, clones each fork, creates a branch from the upstream default branch, pushes it to the fork and opens a PR.
- `.github/workflows/sync-forks.yml` — CI that runs the script on schedule (or manually).

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
- Review PRs before merging; this workflow intentionally opens PRs (not auto-merges) to avoid conflicts and unintended overwrites.

If you want, I can:
- Add labels/reviewers/assignees to created PRs,
- Change schedule or concurrency,
- Provide a small action to automatically close stale sync PRs.
