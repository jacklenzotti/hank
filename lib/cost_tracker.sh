#!/bin/bash
# Cost Tracker Component for Hank
# Logs per-loop cost/token data, computes session totals, displays summaries

# Source date utilities for cross-platform compatibility
source "$(dirname "${BASH_SOURCE[0]}")/date_utils.sh"

# Use HANK_DIR if set by main script, otherwise default to .hank
HANK_DIR="${HANK_DIR:-.hank}"

# Cost tracking files
COST_LOG_FILE="$HANK_DIR/cost_log.jsonl"
COST_SESSION_FILE="$HANK_DIR/.cost_session"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# _update_session_totals - Accumulate running totals in session file
#
# Parameters:
#   $1 (cost_usd) - Cost for this loop
#   $2 (input_tokens) - Input tokens for this loop
#   $3 (output_tokens) - Output tokens for this loop
#   $4 (duration_ms) - Duration for this loop
#   $5 (loops) - Number of loops to add (usually 1)
#
_update_session_totals() {
    local cost_usd="$1"
    local input_tokens="$2"
    local output_tokens="$3"
    local duration_ms="$4"
    local loops="${5:-1}"

    local prev_cost=0 prev_input=0 prev_output=0 prev_duration=0 prev_loops=0

    if [[ -f "$COST_SESSION_FILE" ]] && jq empty "$COST_SESSION_FILE" 2>/dev/null; then
        prev_cost=$(jq -r '.total_cost_usd // 0' "$COST_SESSION_FILE" 2>/dev/null)
        prev_input=$(jq -r '.total_input_tokens // 0' "$COST_SESSION_FILE" 2>/dev/null)
        prev_output=$(jq -r '.total_output_tokens // 0' "$COST_SESSION_FILE" 2>/dev/null)
        prev_duration=$(jq -r '.total_duration_ms // 0' "$COST_SESSION_FILE" 2>/dev/null)
        prev_loops=$(jq -r '.total_loops // 0' "$COST_SESSION_FILE" 2>/dev/null)
    fi

    # Use awk for float addition (never bash arithmetic for floats)
    local new_cost
    new_cost=$(awk "BEGIN {printf \"%.6f\", $prev_cost + $cost_usd}")
    local new_input=$(( $(echo "$prev_input" | awk '{printf "%d", $1+0}') + $(echo "$input_tokens" | awk '{printf "%d", $1+0}') ))
    local new_output=$(( $(echo "$prev_output" | awk '{printf "%d", $1+0}') + $(echo "$output_tokens" | awk '{printf "%d", $1+0}') ))
    local new_duration=$(( $(echo "$prev_duration" | awk '{printf "%d", $1+0}') + $(echo "$duration_ms" | awk '{printf "%d", $1+0}') ))
    local new_loops=$(( $(echo "$prev_loops" | awk '{printf "%d", $1+0}') + $(echo "$loops" | awk '{printf "%d", $1+0}') ))

    jq -n \
        --arg total_cost_usd "$new_cost" \
        --argjson total_input_tokens "$new_input" \
        --argjson total_output_tokens "$new_output" \
        --argjson total_duration_ms "$new_duration" \
        --argjson total_loops "$new_loops" \
        '{
            total_cost_usd: ($total_cost_usd | tonumber),
            total_input_tokens: $total_input_tokens,
            total_output_tokens: $total_output_tokens,
            total_duration_ms: $total_duration_ms,
            total_loops: $total_loops
        }' > "$COST_SESSION_FILE"
}

# record_loop_cost - Extract cost fields from analysis file and append JSONL
#
# Parameters:
#   $1 (loop_number) - Current loop iteration
#   $2 (analysis_file) - Path to .response_analysis JSON
#   $3 (issue_number) - Optional GitHub issue number
#
# Returns:
#   0 - Success (or silently skipped)
#   1 - Missing analysis file
#
record_loop_cost() {
    local loop_number="$1"
    local analysis_file="${2:-$HANK_DIR/.response_analysis}"
    local issue_number="${3:-}"

    if [[ ! -f "$analysis_file" ]]; then
        return 1
    fi

    # Extract cost fields from analysis
    local cost_usd
    cost_usd=$(jq -r '.analysis.cost_usd // 0' "$analysis_file" 2>/dev/null)
    local total_cost_usd
    total_cost_usd=$(jq -r '.analysis.total_cost_usd // 0' "$analysis_file" 2>/dev/null)
    local duration_ms
    duration_ms=$(jq -r '.analysis.duration_ms // 0' "$analysis_file" 2>/dev/null)
    local num_turns
    num_turns=$(jq -r '.analysis.num_turns // 0' "$analysis_file" 2>/dev/null)
    local input_tokens
    input_tokens=$(jq -r '.analysis.usage.input_tokens // 0' "$analysis_file" 2>/dev/null)
    local output_tokens
    output_tokens=$(jq -r '.analysis.usage.output_tokens // 0' "$analysis_file" 2>/dev/null)
    local cache_creation
    cache_creation=$(jq -r '.analysis.usage.cache_creation_input_tokens // 0' "$analysis_file" 2>/dev/null)
    local cache_read
    cache_read=$(jq -r '.analysis.usage.cache_read_input_tokens // 0' "$analysis_file" 2>/dev/null)
    local session_id
    session_id=$(jq -r '.analysis.session_id // ""' "$analysis_file" 2>/dev/null)

    # Sanitize: coerce to numbers, handle null/empty
    cost_usd=$(echo "$cost_usd" | awk '{printf "%.6f", $1+0}')
    total_cost_usd=$(echo "$total_cost_usd" | awk '{printf "%.6f", $1+0}')
    duration_ms=$(echo "$duration_ms" | awk '{printf "%d", $1+0}')
    num_turns=$(echo "$num_turns" | awk '{printf "%d", $1+0}')
    input_tokens=$(echo "$input_tokens" | awk '{printf "%d", $1+0}')
    output_tokens=$(echo "$output_tokens" | awk '{printf "%d", $1+0}')
    cache_creation=$(echo "$cache_creation" | awk '{printf "%d", $1+0}')
    cache_read=$(echo "$cache_read" | awk '{printf "%d", $1+0}')

    # Skip silently when all values are 0 (text mode / older CLI)
    if [[ "$cost_usd" == "0.000000" && "$input_tokens" == "0" && "$output_tokens" == "0" && "$duration_ms" == "0" ]]; then
        return 0
    fi

    # Append JSONL line
    jq -n -c \
        --arg timestamp "$(get_iso_timestamp)" \
        --argjson loop "$loop_number" \
        --arg cost_usd "$cost_usd" \
        --arg total_cost_usd "$total_cost_usd" \
        --argjson duration_ms "$duration_ms" \
        --argjson num_turns "$num_turns" \
        --argjson input_tokens "$input_tokens" \
        --argjson output_tokens "$output_tokens" \
        --argjson cache_creation_input_tokens "$cache_creation" \
        --argjson cache_read_input_tokens "$cache_read" \
        --arg session_id "$session_id" \
        --arg issue_number "$issue_number" \
        '{
            timestamp: $timestamp,
            loop: $loop,
            cost_usd: ($cost_usd | tonumber),
            total_cost_usd: ($total_cost_usd | tonumber),
            duration_ms: $duration_ms,
            num_turns: $num_turns,
            input_tokens: $input_tokens,
            output_tokens: $output_tokens,
            cache_creation_input_tokens: $cache_creation_input_tokens,
            cache_read_input_tokens: $cache_read_input_tokens,
            session_id: $session_id,
            issue_number: $issue_number
        }' >> "$COST_LOG_FILE"

    # Update session totals
    _update_session_totals "$cost_usd" "$input_tokens" "$output_tokens" "$duration_ms" 1

    return 0
}

# show_cost_summary - Display session cost totals
#
# Parameters:
#   $1 (include_per_issue) - "true" to show per-issue breakdown
#
show_cost_summary() {
    local include_per_issue="${1:-false}"

    if [[ ! -f "$COST_SESSION_FILE" ]] || ! jq empty "$COST_SESSION_FILE" 2>/dev/null; then
        return 0
    fi

    local total_cost
    total_cost=$(jq -r '.total_cost_usd // 0' "$COST_SESSION_FILE" 2>/dev/null)
    local total_input
    total_input=$(jq -r '.total_input_tokens // 0' "$COST_SESSION_FILE" 2>/dev/null)
    local total_output
    total_output=$(jq -r '.total_output_tokens // 0' "$COST_SESSION_FILE" 2>/dev/null)
    local total_duration
    total_duration=$(jq -r '.total_duration_ms // 0' "$COST_SESSION_FILE" 2>/dev/null)
    local total_loops
    total_loops=$(jq -r '.total_loops // 0' "$COST_SESSION_FILE" 2>/dev/null)

    # Skip if no cost data
    local cost_check
    cost_check=$(awk "BEGIN {printf \"%d\", ($total_cost * 1000000)}")
    if [[ "$cost_check" == "0" && "$total_input" == "0" ]]; then
        return 0
    fi

    local duration_sec
    duration_sec=$(awk "BEGIN {printf \"%.0f\", $total_duration / 1000}")
    local duration_min
    duration_min=$(awk "BEGIN {printf \"%.1f\", $total_duration / 60000}")

    local avg_cost="0"
    total_loops=$(echo "$total_loops" | awk '{printf "%d", $1+0}')
    if [[ "$total_loops" -gt 0 ]]; then
        avg_cost=$(awk "BEGIN {printf \"%.4f\", $total_cost / $total_loops}")
    fi

    echo ""
    echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║           Cost Summary                                    ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
    echo -e "${YELLOW}Total Cost:${NC}       \$${total_cost}"
    echo -e "${YELLOW}Loops:${NC}            ${total_loops}"
    echo -e "${YELLOW}Avg Cost/Loop:${NC}    \$${avg_cost}"
    echo -e "${YELLOW}Tokens:${NC}           ${total_input} in / ${total_output} out"
    echo -e "${YELLOW}Duration:${NC}         ${duration_min}m (${duration_sec}s)"

    # Per-issue breakdown
    if [[ "$include_per_issue" == "true" && -f "$COST_LOG_FILE" ]]; then
        local issue_summary
        issue_summary=$(jq -s '
            [.[] | select(.issue_number != "" and .issue_number != null)] |
            group_by(.issue_number) |
            map({
                issue: .[0].issue_number,
                cost: (map(.cost_usd) | add),
                loops: length,
                tokens: (map(.input_tokens + .output_tokens) | add)
            }) |
            sort_by(-.cost)
        ' "$COST_LOG_FILE" 2>/dev/null)

        if [[ -n "$issue_summary" && "$issue_summary" != "[]" ]]; then
            echo ""
            echo -e "${YELLOW}Per-Issue Breakdown:${NC}"
            echo "$issue_summary" | jq -r '.[] | "  #\(.issue): $\(.cost | tostring | .[0:8]) (\(.loops) loops, \(.tokens) tokens)"' 2>/dev/null
        fi
    fi

    echo ""
}

# show_cost_report - Full cost report from JSONL log (for --cost-summary flag)
#
show_cost_report() {
    if [[ ! -f "$COST_LOG_FILE" ]]; then
        echo "No cost data found. Run hank to generate cost logs."
        echo "Cost log location: $COST_LOG_FILE"
        return 0
    fi

    # Compute totals from full JSONL file
    local report
    report=$(jq -s '
        {
            total_cost: (map(.cost_usd) | add // 0),
            total_loops: length,
            total_input_tokens: (map(.input_tokens) | add // 0),
            total_output_tokens: (map(.output_tokens) | add // 0),
            total_duration_ms: (map(.duration_ms) | add // 0),
            first_timestamp: (sort_by(.timestamp) | first.timestamp // "unknown"),
            last_timestamp: (sort_by(.timestamp) | last.timestamp // "unknown"),
            per_issue: (
                [.[] | select(.issue_number != "" and .issue_number != null)] |
                group_by(.issue_number) |
                map({
                    issue: .[0].issue_number,
                    cost: (map(.cost_usd) | add),
                    loops: length,
                    tokens: (map(.input_tokens + .output_tokens) | add)
                }) |
                sort_by(-.cost)
            )
        }
    ' "$COST_LOG_FILE" 2>/dev/null)

    if [[ -z "$report" ]]; then
        echo "Cost log is empty or corrupted."
        return 0
    fi

    local total_cost
    total_cost=$(echo "$report" | jq -r '.total_cost')
    local total_loops
    total_loops=$(echo "$report" | jq -r '.total_loops')
    local total_input
    total_input=$(echo "$report" | jq -r '.total_input_tokens')
    local total_output
    total_output=$(echo "$report" | jq -r '.total_output_tokens')
    local total_duration
    total_duration=$(echo "$report" | jq -r '.total_duration_ms')
    local first_ts
    first_ts=$(echo "$report" | jq -r '.first_timestamp')
    local last_ts
    last_ts=$(echo "$report" | jq -r '.last_timestamp')

    local duration_min
    duration_min=$(awk "BEGIN {printf \"%.1f\", $total_duration / 60000}")
    local avg_cost="0"
    if [[ "$total_loops" -gt 0 ]]; then
        avg_cost=$(awk "BEGIN {printf \"%.4f\", $total_cost / $total_loops}")
    fi

    echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║           Hank Cost Report                                ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
    echo -e "${YELLOW}Period:${NC}           $first_ts to $last_ts"
    echo -e "${YELLOW}Total Cost:${NC}       \$${total_cost}"
    echo -e "${YELLOW}Total Loops:${NC}      ${total_loops}"
    echo -e "${YELLOW}Avg Cost/Loop:${NC}    \$${avg_cost}"
    echo -e "${YELLOW}Tokens:${NC}           ${total_input} in / ${total_output} out"
    echo -e "${YELLOW}Duration:${NC}         ${duration_min}m"

    # Per-issue breakdown
    local per_issue
    per_issue=$(echo "$report" | jq -r '.per_issue')
    if [[ -n "$per_issue" && "$per_issue" != "[]" ]]; then
        echo ""
        echo -e "${YELLOW}Per-Issue Breakdown:${NC}"
        echo "$per_issue" | jq -r '.[] | "  #\(.issue): $\(.cost | tostring | .[0:8]) (\(.loops) loops, \(.tokens) tokens)"' 2>/dev/null
    fi

    echo ""
    echo -e "${BLUE}Log file:${NC} $COST_LOG_FILE"
}

# get_issue_cost_summary - Return one-line cost summary for a GitHub issue
#
# Parameters:
#   $1 (issue_number) - GitHub issue number
#
# Outputs:
#   One-line string like "Cost: $0.05 (3 loops, 15000 tokens)" or empty
#
get_issue_cost_summary() {
    local issue_number="$1"

    if [[ -z "$issue_number" || ! -f "$COST_LOG_FILE" ]]; then
        echo ""
        return 0
    fi

    local summary
    summary=$(jq -s --arg issue "$issue_number" '
        [.[] | select(.issue_number == $issue)] |
        if length == 0 then empty
        else {
            cost: (map(.cost_usd) | add),
            loops: length,
            tokens: (map(.input_tokens + .output_tokens) | add)
        } | "Cost: $\(.cost | tostring | .[0:6]) (\(.loops) loops, \(.tokens) tokens)"
        end
    ' "$COST_LOG_FILE" 2>/dev/null)

    echo "${summary:-}"
}

# reset_cost_session - Clear session totals, preserve JSONL log
#
reset_cost_session() {
    rm -f "$COST_SESSION_FILE" 2>/dev/null
}

# Export functions
export -f record_loop_cost
export -f show_cost_summary
export -f show_cost_report
export -f get_issue_cost_summary
export -f reset_cost_session
export -f _update_session_totals
