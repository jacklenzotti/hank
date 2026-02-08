#!/usr/bin/env bash
# Session replay functionality
# Reconstructs timeline of Hank sessions from logs

# Source dependencies
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/date_utils.sh"

# =============================================================================
# Session Discovery
# =============================================================================

# List all available sessions
# Scans audit_log.jsonl, cost_log.jsonl, and .hank_session_history
list_sessions() {
    local hank_dir="${HANK_DIR:-.hank}"
    local sessions_found=()

    # Check if required files exist
    if [[ ! -f "$hank_dir/audit_log.jsonl" ]] && [[ ! -f "$hank_dir/cost_log.jsonl" ]]; then
        echo "No session logs found in $hank_dir/"
        return 1
    fi

    # Extract unique session IDs from audit log
    if [[ -f "$hank_dir/audit_log.jsonl" ]]; then
        sessions_found+=($(jq -r 'select(.session_id != null) | .session_id' "$hank_dir/audit_log.jsonl" 2>/dev/null | sort -u))
    fi

    # Also check cost log
    if [[ -f "$hank_dir/cost_log.jsonl" ]]; then
        sessions_found+=($(jq -r 'select(.session_id != null) | .session_id' "$hank_dir/cost_log.jsonl" 2>/dev/null | sort -u))
    fi

    # Deduplicate
    local unique_sessions=($(printf '%s\n' "${sessions_found[@]}" | sort -u))

    if [[ ${#unique_sessions[@]} -eq 0 ]]; then
        echo "No sessions found with session_id tracking."
        echo "Note: Session tracking was added in recent versions. Old logs may not have session IDs."
        return 1
    fi

    # Display sessions with summary stats
    echo "Available Sessions:"
    echo "===================="
    echo ""

    for session_id in "${unique_sessions[@]}"; do
        show_session_summary "$session_id"
        echo ""
    done
}

# Show summary for a single session
show_session_summary() {
    local session_id="$1"
    local hank_dir="${HANK_DIR:-.hank}"

    # Gather stats from logs
    local loop_count=0
    local total_cost=0
    local issues_worked=()
    local start_time=""
    local end_time=""
    local status="unknown"

    # From cost log
    if [[ -f "$hank_dir/cost_log.jsonl" ]]; then
        loop_count=$(jq -s --arg sid "$session_id" 'map(select(.session_id == $sid)) | length' "$hank_dir/cost_log.jsonl" 2>/dev/null || echo "0")
        total_cost=$(jq -s --arg sid "$session_id" 'map(select(.session_id == $sid)) | map(.cost_usd // 0) | add // 0' "$hank_dir/cost_log.jsonl" 2>/dev/null || echo "0")

        # Get time range
        start_time=$(jq -r --arg sid "$session_id" 'select(.session_id == $sid) | .timestamp' "$hank_dir/cost_log.jsonl" 2>/dev/null | head -1)
        end_time=$(jq -r --arg sid "$session_id" 'select(.session_id == $sid) | .timestamp' "$hank_dir/cost_log.jsonl" 2>/dev/null | tail -1)

        # Get issues worked on (compatible with bash 3.x)
        local issues_raw=$(jq -r --arg sid "$session_id" 'select(.session_id == $sid and .issue_number != null) | .issue_number' "$hank_dir/cost_log.jsonl" 2>/dev/null | sort -u | tr '\n' ' ')
        read -ra issues_worked <<< "$issues_raw"
    fi

    # From audit log - check for completion
    if [[ -f "$hank_dir/audit_log.jsonl" ]]; then
        local exit_event=$(jq -r --arg sid "$session_id" 'select(.session_id == $sid and .event_type == "exit_signal") | .event_type' "$hank_dir/audit_log.jsonl" 2>/dev/null | head -1)
        if [[ -n "$exit_event" ]]; then
            status="completed"
        else
            status="in_progress"
        fi
    fi

    # Format output
    printf "Session: %s\n" "$session_id"
    if [[ -n "$start_time" ]] && [[ -n "$end_time" ]]; then
        printf "  Time: %s to %s\n" "$(date -d "$start_time" '+%Y-%m-%d %H:%M' 2>/dev/null || date -j -f '%Y-%m-%dT%H:%M:%S' "$start_time" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "$start_time")" "$(date -d "$end_time" '+%H:%M' 2>/dev/null || date -j -f '%Y-%m-%dT%H:%M:%S' "$end_time" '+%H:%M' 2>/dev/null || echo "$end_time")"
    fi
    printf "  Loops: %s | Cost: \$%.2f | Status: %s\n" "$loop_count" "$total_cost" "$status"

    if [[ ${#issues_worked[@]} -gt 0 ]]; then
        printf "  Issues: %s\n" "${issues_worked[*]}"
    fi
}

# =============================================================================
# Timeline Reconstruction
# =============================================================================

# Replay a session showing full timeline
replay_session() {
    local session_id="$1"
    local output_format="${2:-human}"  # human or json
    local filter_issue="${3:-}"
    local hank_dir="${HANK_DIR:-.hank}"

    # Validate session exists
    if ! session_exists "$session_id"; then
        echo "Error: Session $session_id not found" >&2
        return 1
    fi

    # Build timeline from multiple sources
    local timeline=()

    # Collect events from audit log
    if [[ -f "$hank_dir/audit_log.jsonl" ]]; then
        while IFS= read -r event; do
            timeline+=("$event")
        done < <(jq -c --arg sid "$session_id" 'select(.session_id == $sid)' "$hank_dir/audit_log.jsonl" 2>/dev/null)
    fi

    # Collect loop data from cost log
    if [[ -f "$hank_dir/cost_log.jsonl" ]]; then
        while IFS= read -r loop_data; do
            # Convert cost log entry to timeline event format
            local loop_event=$(echo "$loop_data" | jq -c '{
                timestamp: .timestamp,
                event_type: "loop_completed",
                session_id: .session_id,
                data: {
                    loop: .loop,
                    cost_usd: .cost_usd,
                    duration_ms: .duration_ms,
                    issue_number: .issue_number,
                    input_tokens: .input_tokens,
                    output_tokens: .output_tokens
                }
            }')
            timeline+=("$loop_event")
        done < <(jq -c --arg sid "$session_id" 'select(.session_id == $sid)' "$hank_dir/cost_log.jsonl" 2>/dev/null)
    fi

    # Sort timeline by timestamp
    local sorted_timeline=$(printf '%s\n' "${timeline[@]}" | jq -s 'sort_by(.timestamp)')

    # Filter by issue if requested
    if [[ -n "$filter_issue" ]]; then
        sorted_timeline=$(echo "$sorted_timeline" | jq --arg issue "$filter_issue" '[.[] | select(.data.issue_number == $issue or .data.issue_number == null)]')
    fi

    # Output based on format
    if [[ "$output_format" == "json" ]]; then
        echo "$sorted_timeline" | jq '.'
    else
        render_timeline_human "$sorted_timeline" "$session_id"
    fi
}

# Check if session exists
session_exists() {
    local session_id="$1"
    local hank_dir="${HANK_DIR:-.hank}"

    # Check audit log
    if [[ -f "$hank_dir/audit_log.jsonl" ]]; then
        local found=$(jq -r --arg sid "$session_id" 'select(.session_id == $sid) | .session_id' "$hank_dir/audit_log.jsonl" 2>/dev/null | head -1)
        if [[ -n "$found" ]]; then
            return 0
        fi
    fi

    # Check cost log
    if [[ -f "$hank_dir/cost_log.jsonl" ]]; then
        local found=$(jq -r --arg sid "$session_id" 'select(.session_id == $sid) | .session_id' "$hank_dir/cost_log.jsonl" 2>/dev/null | head -1)
        if [[ -n "$found" ]]; then
            return 0
        fi
    fi

    return 1
}

# Render timeline in human-readable format
render_timeline_human() {
    local timeline_json="$1"
    local session_id="$2"

    # Calculate session summary
    local loop_count=$(echo "$timeline_json" | jq '[.[] | select(.event_type == "loop_completed")] | length')
    local total_cost=$(echo "$timeline_json" | jq '[.[] | select(.event_type == "loop_completed") | .data.cost_usd // 0] | add // 0')
    local start_time=$(echo "$timeline_json" | jq -r '.[0].timestamp // "unknown"')
    local end_time=$(echo "$timeline_json" | jq -r '.[-1].timestamp // "unknown"')

    # Get unique issues
    local issues=$(echo "$timeline_json" | jq -r '[.[] | select(.data.issue_number != null) | .data.issue_number] | unique | join(", ")')

    # Print header
    echo "========================================"
    echo "Session Replay: $session_id"
    echo "========================================"
    echo ""

    # Format timestamps
    local start_formatted=$(format_timestamp "$start_time")
    local end_formatted=$(format_timestamp "$end_time")

    echo "Time Range: $start_formatted to $end_formatted"
    echo "Total Loops: $loop_count | Total Cost: \$$total_cost"
    if [[ -n "$issues" ]]; then
        echo "Issues Worked: $issues"
    fi
    echo ""
    echo "Timeline:"
    echo "--------"
    echo ""

    # Iterate through events
    local current_loop=0
    echo "$timeline_json" | jq -c '.[]' | while IFS= read -r event; do
        local event_type=$(echo "$event" | jq -r '.event_type')
        local timestamp=$(echo "$event" | jq -r '.timestamp')
        local formatted_time=$(format_timestamp "$timestamp")

        case "$event_type" in
            session_start)
                echo "[$formatted_time] 🚀 Session Started"
                local mode=$(echo "$event" | jq -r '.data.mode // "build"')
                local source=$(echo "$event" | jq -r '.data.source // "local"')
                echo "  Mode: $mode | Source: $source"
                echo ""
                ;;

            loop_start)
                current_loop=$(echo "$event" | jq -r '.data.loop')
                echo "[$formatted_time] Loop $current_loop Started"
                ;;

            loop_completed)
                local loop=$(echo "$event" | jq -r '.data.loop')
                local cost=$(echo "$event" | jq -r '.data.cost_usd // 0')
                local duration=$(echo "$event" | jq -r '.data.duration_ms // 0')
                local issue=$(echo "$event" | jq -r '.data.issue_number // ""')
                local duration_sec=$((duration / 1000))

                echo "[$formatted_time] ✓ Loop $loop Completed (${duration_sec}s, \$${cost})"
                if [[ -n "$issue" ]]; then
                    echo "  Issue: #$issue"
                fi
                echo ""
                ;;

            error_detected)
                local category=$(echo "$event" | jq -r '.data.category // "unknown"')
                local message=$(echo "$event" | jq -r '.data.message // ""' | head -c 80)
                echo "[$formatted_time] ❌ Error Detected: $category"
                if [[ -n "$message" ]]; then
                    echo "  $message"
                fi
                ;;

            retry_attempt)
                local attempt=$(echo "$event" | jq -r '.data.attempt // 0')
                local strategy=$(echo "$event" | jq -r '.data.strategy // "unknown"')
                echo "[$formatted_time] 🔄 Retry Attempt $attempt (strategy: $strategy)"
                ;;

            circuit_breaker_state_change)
                local from=$(echo "$event" | jq -r '.data.from_state // "unknown"')
                local to=$(echo "$event" | jq -r '.data.to_state // "unknown"')
                local reason=$(echo "$event" | jq -r '.data.reason // ""')
                echo "[$formatted_time] 🔌 Circuit Breaker: $from → $to"
                if [[ -n "$reason" ]]; then
                    echo "  Reason: $reason"
                fi
                ;;

            task_sync)
                local source=$(echo "$event" | jq -r '.data.source // "unknown"')
                local count=$(echo "$event" | jq -r '.data.task_count // 0')
                echo "[$formatted_time] 📋 Tasks Synced from $source ($count tasks)"
                ;;

            issue_closed)
                local issue=$(echo "$event" | jq -r '.data.issue_number // ""')
                echo "[$formatted_time] ✅ Issue #$issue Closed"
                ;;

            exit_signal)
                local reason=$(echo "$event" | jq -r '.data.reason // "unknown"')
                echo "[$formatted_time] 🏁 Exit Signal: $reason"
                ;;

            *)
                # Generic event display
                echo "[$formatted_time] $event_type"
                ;;
        esac
    done

    echo ""
    echo "========================================"
    echo "End of Session Replay"
    echo "========================================"
}

# Format timestamp for display
format_timestamp() {
    local timestamp="$1"

    # Try GNU date
    if date -d "$timestamp" '+%Y-%m-%d %H:%M:%S' 2>/dev/null; then
        return 0
    fi

    # Try BSD date (macOS)
    if date -j -f '%Y-%m-%dT%H:%M:%S' "${timestamp:0:19}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null; then
        return 0
    fi

    # Fallback: return as-is
    echo "$timestamp"
}

# =============================================================================
# Export Functions
# =============================================================================

export -f list_sessions
export -f show_session_summary
export -f replay_session
export -f session_exists
export -f render_timeline_human
export -f format_timestamp
