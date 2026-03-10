#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# GitLab to GitHub Migration Script
# Migrates all accessible repos from self-hosted GitLab
# to a GitHub organization with full git history.
# ============================================================

# Load .env file if it exists
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
    set -a
    source "${SCRIPT_DIR}/.env"
    set +a
fi

GITLAB_URL="https://gitlab.path.com.tr"
GITHUB_ORG="pathcomtr"

# Tokens - set these as environment variables or fill in here
GITLAB_TOKEN="${GITLAB_TOKEN:-}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"

# Filter by GitLab group (set via --group flag)
GITLAB_GROUP=""

# Directory to clone repos temporarily
WORK_DIR="$(pwd)/repos"

# ============================================================

usage() {
    echo "Usage: $0 [--group <gitlab-group-path>] [--list-groups] [--parallel N]"
    echo ""
    echo "Options:"
    echo "  --group <path>   Only migrate repos from this GitLab group (e.g. 'myteam' or 'myteam/subgroup')"
    echo "  --list-groups    List all available GitLab groups and exit"
    echo "  --parallel N     Run N migrations in parallel (default: 1, recommended: 4)"
    echo "  --dry-run        Show what would be migrated without doing anything"
    echo "  --delete-source  Delete GitLab repo after successful migration (requires api scope on token)"
    echo "  -h, --help       Show this help"
    echo ""
    echo "Examples:"
    echo "  $0 --list-groups"
    echo "  $0 --group myteam --dry-run"
    echo "  $0 --group myteam                    # sequential migration"
    echo "  $0 --group myteam --parallel 4       # 4 repos at a time"
    exit 0
}

# Parse arguments
DRY_RUN=false
LIST_GROUPS=false
DELETE_SOURCE=false
PARALLEL_JOBS=1

while [[ $# -gt 0 ]]; do
    case "$1" in
        --group)
            GITLAB_GROUP="$2"
            shift 2
            ;;
        --list-groups)
            LIST_GROUPS=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --delete-source)
            DELETE_SOURCE=true
            shift
            ;;
        --parallel)
            PARALLEL_JOBS="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            error "Unknown option: $1"
            usage
            ;;
    esac
done

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

log()   { echo -e "${GREEN}[INFO]${NC} $*" >&2; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# Draw a progress bar
# Usage: draw_progress <completed> <failed> <total> <current_repo>
draw_progress() {
    local completed="$1"
    local failed="$2"
    local total="$3"
    local current="$4"
    local done_total=$((completed + failed))
    local percent=0
    if [[ "$total" -gt 0 ]]; then
        percent=$((done_total * 100 / total))
    fi

    # Bar width
    local bar_width=40
    local filled=$((done_total * bar_width / total))
    local empty=$((bar_width - filled))

    # Build bar string
    local bar=""
    for ((b=0; b<filled; b++)); do bar+="█"; done
    for ((b=0; b<empty; b++)); do bar+="░"; done

    # Status line
    local status_line="${BOLD}${CYAN}[${bar}]${NC} ${percent}%  ${GREEN}✓${completed}${NC} ${RED}✗${failed}${NC} / ${total}"

    # Get terminal width for truncation
    local term_width
    term_width=$(tput cols 2>/dev/null || echo 80)

    # Current repo info
    local repo_line=""
    if [[ -n "$current" ]]; then
        repo_line="  ${DIM}⟳ ${current}${NC}"
    fi

    # Move cursor up, clear lines, redraw
    printf "\r\033[K%b\n\033[K%b\033[2A" "$status_line" "$repo_line" >&2
}

# Final progress draw (moves cursor to end)
finish_progress() {
    local completed="$1"
    local failed="$2"
    local total="$3"

    local bar_width=40
    local bar=""
    for ((b=0; b<bar_width; b++)); do bar+="█"; done

    local color="${GREEN}"
    if [[ "$failed" -gt 0 ]]; then color="${YELLOW}"; fi

    printf "\r\033[K${BOLD}${color}[${bar}]${NC} 100%%  ${GREEN}✓${completed}${NC} ${RED}✗${failed}${NC} / ${total}\n\033[K\n" >&2
}

# Validate prerequisites
check_prerequisites() {
    if [[ -z "$GITLAB_TOKEN" ]]; then
        error "GITLAB_TOKEN is not set. Export it or set it in this script."
        echo "  Generate one at: ${GITLAB_URL}/-/profile/personal_access_tokens"
        echo "  Required scopes: read_api, read_repository"
        exit 1
    fi

    if [[ -z "$GITHUB_TOKEN" ]]; then
        error "GITHUB_TOKEN is not set. Export it or set it in this script."
        echo "  Generate one at: https://github.com/settings/tokens"
        echo "  Required scopes: repo, admin:org (to create repos)"
        exit 1
    fi

    for cmd in git curl jq; do
        if ! command -v "$cmd" &>/dev/null; then
            error "'$cmd' is required but not installed."
            exit 1
        fi
    done
}

# List all accessible GitLab groups
list_gitlab_groups() {
    local page=1
    local per_page=100

    log "Fetching groups from GitLab..."
    echo ""

    while true; do
        local response
        response=$(curl -s --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
            "${GITLAB_URL}/api/v4/groups?per_page=${per_page}&page=${page}")

        # Check if response is a valid array
        if ! echo "$response" | jq -e 'type == "array"' &>/dev/null; then
            error "Unexpected API response: $response"
            break
        fi

        local count
        count=$(echo "$response" | jq 'length')

        if [[ "$count" -eq 0 ]]; then
            break
        fi

        echo "$response" | jq -r '.[] | "  \(.full_path)\t(\(.name)) - \(.description // "no description")"'
        page=$((page + 1))
    done
}

# Resolve GitLab group ID from path
resolve_group_id() {
    local group_path="$1"
    local encoded_path
    encoded_path=$(printf '%s' "$group_path" | jq -sRr @uri)

    local response
    response=$(curl -s --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
        "${GITLAB_URL}/api/v4/groups/${encoded_path}")

    local group_id
    group_id=$(echo "$response" | jq -r '.id // empty')

    if [[ -z "$group_id" ]]; then
        error "Group '${group_path}' not found. Use --list-groups to see available groups."
        exit 1
    fi

    echo "$group_id"
}

# Fetch all projects from GitLab (handles pagination)
fetch_gitlab_projects() {
    local page=1
    local per_page=100
    local all_projects="[]"
    local api_endpoint

    if [[ -n "$GITLAB_GROUP" ]]; then
        local group_id
        group_id=$(resolve_group_id "$GITLAB_GROUP")
        api_endpoint="${GITLAB_URL}/api/v4/groups/${group_id}/projects?include_subgroups=true&per_page=${per_page}&archived=false"
        log "Fetching projects from GitLab group '${GITLAB_GROUP}' (id: ${group_id})..."
    else
        api_endpoint="${GITLAB_URL}/api/v4/projects?membership=true&per_page=${per_page}&archived=false"
        log "Fetching all accessible projects from GitLab..."
    fi

    while true; do
        local response
        response=$(curl -s --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
            "${api_endpoint}&page=${page}")

        # Validate response is a JSON array
        if ! echo "$response" | jq -e 'type == "array"' &>/dev/null; then
            error "Unexpected API response on page ${page}: $(echo "$response" | head -c 200)"
            break
        fi

        local count
        count=$(echo "$response" | jq 'length')

        if [[ "$count" -eq 0 ]]; then
            break
        fi

        all_projects=$(jq -s 'add' <(echo "$all_projects") <(echo "$response"))
        log "  Fetched page $page ($count projects)"
        page=$((page + 1))
    done

    local total
    total=$(echo "$all_projects" | jq 'length')
    log "Total projects found: $total"

    echo "$all_projects"
}

# Create a GitHub repo if it doesn't exist
create_github_repo() {
    local repo_name="$1"
    local description="$2"
    local visibility="$3"

    local private_flag="true"
    if [[ "$visibility" == "public" ]]; then
        private_flag="false"
    fi

    # Check if repo already exists
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        -H "Authorization: token ${GITHUB_TOKEN}" \
        -H "Accept: application/vnd.github.v3+json" \
        "https://api.github.com/repos/${GITHUB_ORG}/${repo_name}")

    if [[ "$http_code" == "200" ]]; then
        warn "GitHub repo '${GITHUB_ORG}/${repo_name}' already exists, skipping creation."
        return 0
    fi

    log "Creating GitHub repo: ${GITHUB_ORG}/${repo_name} (private=${private_flag})"
    local result
    result=$(curl -s -w "\n%{http_code}" \
        -H "Authorization: token ${GITHUB_TOKEN}" \
        -H "Accept: application/vnd.github.v3+json" \
        "https://api.github.com/orgs/${GITHUB_ORG}/repos" \
        -d "{
            \"name\": \"${repo_name}\",
            \"description\": $(echo "$description" | jq -Rs 'gsub("[\\u0000-\\u001f\\u007f]"; "")'),
            \"private\": ${private_flag},
            \"has_issues\": true,
            \"has_projects\": false,
            \"has_wiki\": false
        }")

    local body http_status
    body=$(echo "$result" | sed '$d')
    http_status=$(echo "$result" | tail -1)

    if [[ "$http_status" -ge 200 && "$http_status" -lt 300 ]]; then
        return 0
    else
        error "Failed to create repo '${repo_name}': HTTP ${http_status}"
        (echo "$body" | jq -r '(.message // "") + " " + ((.errors // []) | map(.message // (.code + " on " + .field)) | join("; "))' 2>/dev/null || echo "$body") >&2
        return 1
    fi
}

# Mirror a single repo from GitLab to GitHub
mirror_repo() {
    local gitlab_http_url="$1"
    local repo_name="$2"
    local repo_dir="${WORK_DIR}/${repo_name}"

    # Inject token into GitLab clone URL
    local gitlab_clone_url
    gitlab_clone_url=$(echo "$gitlab_http_url" | sed "s|https://|https://oauth2:${GITLAB_TOKEN}@|")

    local github_push_url="https://${GITHUB_TOKEN}@github.com/${GITHUB_ORG}/${repo_name}.git"

    log "Cloning (bare): ${gitlab_http_url}"
    if [[ -d "$repo_dir" ]]; then
        rm -rf "$repo_dir"
    fi

    if ! git clone --bare "$gitlab_clone_url" "$repo_dir" 2>/dev/null; then
        error "Failed to clone '${gitlab_http_url}'"
        return 1
    fi

    log "Pushing to GitHub: ${GITHUB_ORG}/${repo_name}"
    cd "$repo_dir"

    if ! git push --mirror "$github_push_url" 2>/dev/null; then
        error "Failed to push '${repo_name}' to GitHub"
        cd - >/dev/null
        return 1
    fi

    cd - >/dev/null
    rm -rf "$repo_dir"
    return 0
}

# Delete a GitLab project
delete_gitlab_project() {
    local project_id="$1"
    local project_path="$2"

    log "Deleting GitLab project: ${project_path} (id: ${project_id})"
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        --request DELETE \
        --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
        "${GITLAB_URL}/api/v4/projects/${project_id}")

    if [[ "$http_code" == "202" || "$http_code" == "204" ]]; then
        log "Deleted GitLab project: ${project_path}"
        return 0
    else
        error "Failed to delete GitLab project '${project_path}': HTTP ${http_code}"
        return 1
    fi
}

# Migrate a single repo end-to-end (used by both sequential and parallel modes)
# Writes result to a status file: "ok", "ok_deleted", or "fail:<path>"
migrate_single_repo() {
    local index="$1"
    local total="$2"
    local name="$3"
    local path="$4"
    local description="$5"
    local visibility="$6"
    local http_url="$7"
    local project_id="$8"
    local github_repo_name="$9"
    local status_file="${10}"

    # Write "in progress" marker
    echo "running:${path}" > "$status_file"

    local log_file="${status_file%.status}.log"

    if create_github_repo "$github_repo_name" "$description" "$visibility" 2>>"$log_file"; then
        if mirror_repo "$http_url" "$github_repo_name" 2>>"$log_file"; then
            if [[ "$DELETE_SOURCE" == true ]]; then
                if delete_gitlab_project "$project_id" "$path" 2>>"$log_file"; then
                    echo "ok_deleted" > "$status_file"
                else
                    echo "ok" > "$status_file"
                fi
            else
                echo "ok" > "$status_file"
            fi
            return 0
        fi
    fi

    echo "fail:${path}" > "$status_file"
    return 1
}

# Main
main() {
    check_prerequisites

    # Handle --list-groups
    if [[ "$LIST_GROUPS" == true ]]; then
        list_gitlab_groups
        exit 0
    fi

    mkdir -p "$WORK_DIR"

    local projects
    projects=$(fetch_gitlab_projects)

    local total
    total=$(echo "$projects" | jq 'length')

    if [[ "$total" -eq 0 ]]; then
        warn "No projects found. Check your GITLAB_TOKEN permissions."
        exit 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        log "[DRY RUN] Would migrate $total repositories (parallel: ${PARALLEL_JOBS}):"
        echo ""
        for i in $(seq 0 $((total - 1))); do
            local path visibility
            path=$(echo "$projects" | jq -r ".[$i].path_with_namespace")
            visibility=$(echo "$projects" | jq -r ".[$i].visibility")
            local github_repo_name
            github_repo_name=$(echo "$path" | tr '/' '-' | sed -e 's/test/t3st/g' -e 's/ansible/ansibl3/g')
            echo -e "  ${path} -> ${GITHUB_ORG}/${github_repo_name} (${visibility})"
        done
        echo ""
        if [[ "$DELETE_SOURCE" == true ]]; then
            warn "[DRY RUN] --delete-source is enabled: GitLab repos would be DELETED after migration."
        fi
        log "[DRY RUN] No changes made."
        exit 0
    fi

    log "Starting migration of $total repositories (parallel: ${PARALLEL_JOBS})..."

    if [[ "$DELETE_SOURCE" == true ]]; then
        warn "--delete-source is enabled. GitLab repos will be DELETED after successful migration!"
        warn "You have 5 seconds to cancel (Ctrl+C)..."
        sleep 5
    fi

    # Create temp dir for status files
    local status_dir
    status_dir=$(mktemp -d)

    # Reserve 2 lines for progress bar
    echo "" >&2
    echo "" >&2

    # Draw initial progress
    draw_progress 0 0 "$total" "starting..."

    local running=0

    for i in $(seq 0 $((total - 1))); do
        local name path description visibility http_url project_id github_repo_name
        name=$(echo "$projects" | jq -r ".[$i].path")
        path=$(echo "$projects" | jq -r ".[$i].path_with_namespace")
        description=$(echo "$projects" | jq -r ".[$i].description // \"Migrated from GitLab: ${path}\"" | tr -d '\000-\037' | sed -e 's/test/t3st/g' -e 's/ansible/ansibl3/g')
        visibility=$(echo "$projects" | jq -r ".[$i].visibility")
        http_url=$(echo "$projects" | jq -r ".[$i].http_url_to_repo")
        project_id=$(echo "$projects" | jq -r ".[$i].id")
        github_repo_name=$(echo "$path" | tr '/' '-' | sed -e 's/test/t3st/g' -e 's/ansible/ansibl3/g')

        local status_file="${status_dir}/${i}.status"

        migrate_single_repo "$((i + 1))" "$total" "$name" "$path" "$description" "$visibility" "$http_url" "$project_id" "$github_repo_name" "$status_file" &

        running=$((running + 1))

        # Wait for batch to finish if we hit the parallel limit
        if [[ "$running" -ge "$PARALLEL_JOBS" ]]; then
            # Poll progress while waiting
            while true; do
                local done_jobs=0
                local ok_count=0
                local fail_count=0
                local current_repos=""

                for j in $(seq 0 $((total - 1))); do
                    local sf="${status_dir}/${j}.status"
                    if [[ -f "$sf" ]]; then
                        local st
                        st=$(cat "$sf" 2>/dev/null || echo "")
                        case "$st" in
                            ok|ok_deleted) ok_count=$((ok_count + 1)); done_jobs=$((done_jobs + 1)) ;;
                            fail:*) fail_count=$((fail_count + 1)); done_jobs=$((done_jobs + 1)) ;;
                            running:*) current_repos="${st#running:}" ;;
                        esac
                    fi
                done

                draw_progress "$ok_count" "$fail_count" "$total" "$current_repos"

                # Check if all current batch jobs are done
                if ! jobs -r %% &>/dev/null 2>&1; then
                    wait 2>/dev/null
                    break
                fi
                if wait -n 2>/dev/null; then
                    :
                else
                    :
                fi
                break
            done
            running=0
        fi
    done

    # Wait for remaining jobs with progress polling
    while true; do
        local ok_count=0
        local fail_count=0
        local done_jobs=0
        local current_repos=""

        for j in $(seq 0 $((total - 1))); do
            local sf="${status_dir}/${j}.status"
            if [[ -f "$sf" ]]; then
                local st
                st=$(cat "$sf" 2>/dev/null || echo "")
                case "$st" in
                    ok|ok_deleted) ok_count=$((ok_count + 1)); done_jobs=$((done_jobs + 1)) ;;
                    fail:*) fail_count=$((fail_count + 1)); done_jobs=$((done_jobs + 1)) ;;
                    running:*) current_repos="${st#running:}" ;;
                esac
            fi
        done

        draw_progress "$ok_count" "$fail_count" "$total" "$current_repos"

        if [[ "$done_jobs" -ge "$total" ]]; then
            break
        fi

        sleep 1
    done

    wait 2>/dev/null

    # Collect final results
    local success=0
    local failed=0
    local deleted=0
    local failed_repos=""

    for i in $(seq 0 $((total - 1))); do
        local status_file="${status_dir}/${i}.status"
        if [[ -f "$status_file" ]]; then
            local result
            result=$(cat "$status_file")
            case "$result" in
                ok)
                    success=$((success + 1))
                    ;;
                ok_deleted)
                    success=$((success + 1))
                    deleted=$((deleted + 1))
                    ;;
                fail:*)
                    failed=$((failed + 1))
                    local log_file="${status_file%.status}.log"
                    local log_content=""
                    if [[ -f "$log_file" ]]; then
                        log_content=$(cat "$log_file")
                    fi
                    failed_repos="${failed_repos}\n  - ${result#fail:}"
                    if [[ -n "$log_content" ]]; then
                        failed_repos="${failed_repos}\n$(echo "$log_content" | sed 's/^/      /')"
                    fi
                    ;;
            esac
        else
            failed=$((failed + 1))
        fi
    done

    # Final progress bar
    finish_progress "$success" "$failed" "$total"

    # Cleanup
    rm -rf "$status_dir"
    rmdir "$WORK_DIR" 2>/dev/null || true

    # Summary
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" >&2
    log "Migration complete!"
    log "  Successful: $success"
    if [[ "$deleted" -gt 0 ]]; then
        log "  Deleted from GitLab: $deleted"
    fi
    if [[ "$failed" -gt 0 ]]; then
        error "  Failed: $failed"
        echo -e "  Failed repos:${failed_repos}" >&2
    fi
}

main "$@"
