# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Bash-based migration tool that mirrors repositories from a self-hosted GitLab instance (`gitlab.path.com.tr`) to a GitHub organization (`pathcomtr`). Performs bare clone + mirror push to transfer all branches, tags, and full git history. Supports parallel execution with a live progress bar.

## Key File

- `migrate.sh` — Single migration script. Loads tokens from `.env`, interacts with GitLab API v4 and GitHub API v3.

## Configuration

Tokens are loaded from `.env` file (auto-sourced by the script):
- `GITLAB_TOKEN` — needs `api` scope (for delete) or `read_api` + `read_repository`
- `GITHUB_TOKEN` — needs `repo` + `admin:org` scopes

## Common Commands

```bash
# List all GitLab groups
./migrate.sh --list-groups

# Preview what would be migrated (no changes)
./migrate.sh --group <group-path> --dry-run

# Migrate a specific group (sequential)
./migrate.sh --group <group-path>

# Migrate with parallelism (recommended: 4)
./migrate.sh --group <group-path> --parallel 4

# Migrate and delete source repos from GitLab
./migrate.sh --group <group-path> --delete-source

# Migrate all accessible repos (no group filter)
./migrate.sh
```

## Architecture Notes

- Repo naming: GitLab `group/subgroup/repo` becomes GitHub `group-subgroup-repo` (slashes replaced with hyphens)
- All repos are created as **private** on GitHub regardless of GitLab visibility
- The script is idempotent — skips GitHub repo creation if it already exists
- `log()` and `warn()` output to stderr so they don't interfere with function return values captured via stdout (critical for functions like `fetch_gitlab_projects` and `resolve_group_id` that return data via stdout)
- `migrate_single_repo()` runs in background subprocesses; each writes status to a file in a temp directory (`ok`, `ok_deleted`, `fail:<path>`, or `running:<path>`)
- Progress bar (`draw_progress`/`finish_progress`) polls status files every second and redraws in-place using ANSI escape codes
- `--parallel N` launches repos in batches of N background jobs, waiting for each batch before starting the next
- Temporary bare clones are stored in `./repos/` and cleaned up after each push
- `--delete-source` adds a 5-second safety delay before starting
- GitHub's Source Import API is deprecated (404 as of 2024) — only local clone+push works

## Dependencies

Requires: `git`, `curl`, `jq` (all expected on macOS via Homebrew)
