#!/bin/bash
# Orchestrator Component for Hank
# Multi-repo configuration and dependency resolution

# Source date utilities for cross-platform compatibility
source "$(dirname "${BASH_SOURCE[0]}")/date_utils.sh"

# Source audit_log.sh if not already sourced
if ! declare -f audit_event >/dev/null 2>&1; then
    source "$(dirname "${BASH_SOURCE[0]}")/audit_log.sh"
fi

# Use HANK_DIR if set by main script, otherwise default to .hank
HANK_DIR="${HANK_DIR:-.hank}"

# Orchestration files
REPOS_CONFIG_FILE="$HANK_DIR/.repos.json"
ORCHESTRATION_STATE_FILE="$HANK_DIR/.orchestration_state"
ORCHESTRATION_COST_FILE="$HANK_DIR/orchestration_cost.jsonl"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# load_repo_config - Load and validate multi-repo configuration
#
# Parameters:
#   $1 (config_file) - Path to .repos.json (default: $REPOS_CONFIG_FILE)
#
# Returns:
#   0 - Success, config loaded
#   1 - Config file missing or invalid
#
load_repo_config() {
    local config_file="${1:-$REPOS_CONFIG_FILE}"

    if [[ ! -f "$config_file" ]]; then
        echo "ERROR: Repo config file not found: $config_file" >&2
        return 1
    fi

    # Validate JSON
    if ! jq empty "$config_file" 2>/dev/null; then
        echo "ERROR: Invalid JSON in repo config: $config_file" >&2
        return 1
    fi

    # Validate array format
    if ! jq -e 'type == "array"' "$config_file" >/dev/null 2>&1; then
        echo "ERROR: Repo config must be a JSON array" >&2
        return 1
    fi

    # Validate each repo entry
    local validation_errors=$(jq -r '
        .[] |
        select(
            (.name | type != "string") or
            (.path | type != "string") or
            (.deps | type != "array")
        ) |
        "Invalid repo entry: missing name, path, or deps field"
    ' "$config_file" 2>/dev/null)

    if [[ -n "$validation_errors" ]]; then
        echo "ERROR: $validation_errors" >&2
        return 1
    fi

    # Validate paths exist
    local missing_paths=$(jq -r '.[] | .path' "$config_file" | while read -r path; do
        if [[ ! -d "$path" ]]; then
            echo "$path"
        fi
    done)

    if [[ -n "$missing_paths" ]]; then
        echo "ERROR: Repository paths do not exist:" >&2
        echo "$missing_paths" >&2
        return 1
    fi

    return 0
}

# detect_circular_dependencies - Check for circular dependencies in repo config
#
# Parameters:
#   $1 (config_file) - Path to .repos.json
#
# Returns:
#   0 - No circular dependencies
#   1 - Circular dependency detected
#
detect_circular_dependencies() {
    local config_file="${1:-$REPOS_CONFIG_FILE}"

    # Use DFS to detect cycles
    local result=$(jq -r '
        # Build adjacency map
        reduce .[] as $repo (
            {};
            .[$repo.name] = $repo.deps
        ) as $graph |

        # DFS function to detect cycles
        def has_cycle($node; $visiting; $visited):
            if ($visiting | index($node)) then
                true
            elif ($visited | index($node)) then
                false
            else
                $visiting + [$node] as $new_visiting |
                $visited as $curr_visited |
                (
                    $graph[$node] // [] |
                    map(has_cycle(.; $new_visiting; $curr_visited)) |
                    any
                )
            end;

        # Check all nodes
        [
            $graph | keys[] as $node |
            has_cycle($node; []; [])
        ] |
        if any then "CYCLE_DETECTED" else "NO_CYCLE" end
    ' "$config_file" 2>/dev/null)

    if [[ "$result" == "CYCLE_DETECTED" ]]; then
        echo "ERROR: Circular dependency detected in repo configuration" >&2
        return 1
    fi

    return 0
}

# resolve_execution_order - Topological sort of repos by dependencies
#
# Parameters:
#   $1 (config_file) - Path to .repos.json
#
# Returns:
#   Space-separated list of repo names in execution order
#
resolve_execution_order() {
    local config_file="${1:-$REPOS_CONFIG_FILE}"

    # Topological sort using Kahn's algorithm
    local order=$(jq -r '
        # Build adjacency list and in-degree count
        reduce .[] as $repo (
            {graph: {}, in_degree: {}, nodes: []};
            .nodes += [$repo.name] |
            .graph[$repo.name] = $repo.deps |
            .in_degree[$repo.name] = ($repo.deps | length)
        ) as $data |

        # Kahn algorithm
        def topo_sort:
            # Find nodes with in-degree 0
            [$data.nodes[] | select($data.in_degree[.] == 0)] as $queue |

            # Process queue
            def process($q; $result; $degrees):
                if ($q | length == 0) then
                    $result
                else
                    $q[0] as $node |
                    $q[1:] as $rest |

                    # Reduce in-degree for dependents
                    reduce ($data.nodes[] | select($data.graph[.] | index($node))) as $dependent (
                        {queue: $rest, degrees: $degrees};
                        .degrees[$dependent] = (.degrees[$dependent] - 1) |
                        if .degrees[$dependent] == 0 then
                            .queue += [$dependent]
                        else
                            .
                        end
                    ) |

                    process(.queue; $result + [$node]; .degrees)
                end;

            process($queue; []; $data.in_degree);

        topo_sort | join(" ")
    ' "$config_file" 2>/dev/null)

    echo "$order"
}

# init_orchestration_state - Initialize orchestration state file
#
# Parameters:
#   $1 (config_file) - Path to .repos.json
#
init_orchestration_state() {
    local config_file="${1:-$REPOS_CONFIG_FILE}"

    # Create initial state from config
    jq -n \
        --slurpfile config "$config_file" \
        '{
            active: true,
            started_at: (now | todate),
            repos: (
                $config[0] |
                map({
                    key: .name,
                    value: {
                        status: "pending",
                        loops: 0,
                        cost_usd: 0,
                        blocked_by: []
                    }
                }) |
                from_entries
            ),
            total_cost_usd: 0,
            completed_repos: [],
            blocked_repos: [],
            current_repo: null
        }' > "$ORCHESTRATION_STATE_FILE"

    # Record audit event
    if declare -f audit_event >/dev/null 2>&1; then
        local repo_count=$(jq 'length' "$config_file")
        audit_event "orchestration_started" "{\"repo_count\":$repo_count}"
    fi
}

# get_next_repo - Get next repo to work on
#
# Returns:
#   Repo name to work on, or empty if all complete/blocked
#
get_next_repo() {
    if [[ ! -f "$ORCHESTRATION_STATE_FILE" ]]; then
        return 1
    fi

    local next_repo=$(jq -r '
        .repos |
        to_entries |
        map(select(.value.status == "pending" or .value.status == "in_progress")) |
        map(select((.value.blocked_by | length) == 0)) |
        sort_by(.value.priority // 999) |
        .[0].key // empty
    ' "$ORCHESTRATION_STATE_FILE" 2>/dev/null)

    echo "$next_repo"
}

# is_repo_blocked - Check if repo is blocked by dependencies
#
# Parameters:
#   $1 (repo_name) - Repository name
#
# Returns:
#   0 - Not blocked
#   1 - Blocked by dependencies
#
is_repo_blocked() {
    local repo_name="$1"

    if [[ ! -f "$ORCHESTRATION_STATE_FILE" ]]; then
        return 0
    fi

    local blocked_count=$(jq -r \
        --arg repo "$repo_name" \
        '.repos[$repo].blocked_by | length' \
        "$ORCHESTRATION_STATE_FILE" 2>/dev/null)

    [[ "$blocked_count" -gt 0 ]]
}

# mark_repo_complete - Mark repository as completed
#
# Parameters:
#   $1 (repo_name) - Repository name
#   $2 (loops) - Number of loops executed
#   $3 (cost_usd) - Total cost for this repo
#
mark_repo_complete() {
    local repo_name="$1"
    local loops="${2:-0}"
    local cost_usd="${3:-0}"

    if [[ ! -f "$ORCHESTRATION_STATE_FILE" ]]; then
        return 1
    fi

    # Update state
    local updated_state=$(jq \
        --arg repo "$repo_name" \
        --argjson loops "$loops" \
        --arg cost "$cost_usd" \
        '
        .repos[$repo].status = "completed" |
        .repos[$repo].loops = $loops |
        .repos[$repo].cost_usd = ($cost | tonumber) |
        .repos[$repo].completed_at = (now | todate) |
        .completed_repos += [$repo] |
        .total_cost_usd = (.repos | to_entries | map(.value.cost_usd) | add) |

        # Unblock dependent repos
        .repos |= (
            to_entries |
            map(
                .value.blocked_by |= (map(select(. != $repo)))
            ) |
            from_entries
        )
        ' "$ORCHESTRATION_STATE_FILE")

    echo "$updated_state" > "$ORCHESTRATION_STATE_FILE"

    # Record audit event
    if declare -f audit_event >/dev/null 2>&1; then
        audit_event "repo_completed" "{\"repo\":\"$repo_name\",\"loops\":$loops,\"cost_usd\":\"$cost_usd\"}"
    fi

    echo -e "${GREEN}✓ Repo '$repo_name' completed ($loops loops, \$$cost_usd)${NC}"
}

# mark_repo_blocked - Mark repository as blocked
#
# Parameters:
#   $1 (repo_name) - Repository name
#   $2 (reason) - Reason for blocking
#
mark_repo_blocked() {
    local repo_name="$1"
    local reason="${2:-Unknown error}"

    if [[ ! -f "$ORCHESTRATION_STATE_FILE" ]]; then
        return 1
    fi

    # Update state
    local updated_state=$(jq \
        --arg repo "$repo_name" \
        --arg reason "$reason" \
        '
        .repos[$repo].status = "blocked" |
        .repos[$repo].block_reason = $reason |
        .blocked_repos += [$repo]
        ' "$ORCHESTRATION_STATE_FILE")

    echo "$updated_state" > "$ORCHESTRATION_STATE_FILE"

    # Record audit event
    if declare -f audit_event >/dev/null 2>&1; then
        audit_event "repo_blocked" "{\"repo\":\"$repo_name\",\"reason\":\"$reason\"}"
    fi

    echo -e "${RED}✗ Repo '$repo_name' blocked: $reason${NC}"
}

# show_orchestration_status - Display current orchestration status
#
show_orchestration_status() {
    if [[ ! -f "$ORCHESTRATION_STATE_FILE" ]]; then
        echo "No orchestration in progress."
        return 0
    fi

    local state=$(cat "$ORCHESTRATION_STATE_FILE")

    echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║           Orchestration Status                            ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"

    local total_repos=$(echo "$state" | jq -r '.repos | length')
    local completed=$(echo "$state" | jq -r '.completed_repos | length')
    local blocked=$(echo "$state" | jq -r '.blocked_repos | length')
    local total_cost=$(echo "$state" | jq -r '.total_cost_usd')
    local current=$(echo "$state" | jq -r '.current_repo // "none"')

    echo -e "${YELLOW}Total Repos:${NC}      $total_repos"
    echo -e "${GREEN}Completed:${NC}        $completed"
    echo -e "${RED}Blocked:${NC}          $blocked"
    echo -e "${YELLOW}Current:${NC}          $current"
    echo -e "${YELLOW}Total Cost:${NC}       \$$total_cost"
    echo ""
    echo -e "${YELLOW}Repository Details:${NC}"

    echo "$state" | jq -r '
        .repos |
        to_entries |
        map(
            "\(.key): \(.value.status) (\(.value.loops) loops, $\(.value.cost_usd))" +
            (if (.value.blocked_by | length) > 0 then " - blocked by: \(.value.blocked_by | join(", "))" else "" end)
        )[]
    ' | while read -r line; do
        echo "  $line"
    done

    echo ""
}

# Export functions
export -f load_repo_config
export -f detect_circular_dependencies
export -f resolve_execution_order
export -f init_orchestration_state
export -f get_next_repo
export -f is_repo_blocked
export -f mark_repo_complete
export -f mark_repo_blocked
export -f show_orchestration_status
